//
//  VNCRFBClient.swift
//  CatusshModule
//
//  The RFB session state machine: banner → security → init → encodings →
//  the read loop that turns rectangles into framebuffer updates and
//  clipboard/cursor events. Runs on one reader thread; outbound messages
//  are written under a lock so input calls from the UI thread interleave
//  safely with the update loop.
//

import CoreGraphics
import Foundation

/// The events a session reports back, delivered on the client's reader
/// thread — the driver forwards them into the main-actor session.
protocol VNCRFBClientDelegate: AnyObject, Sendable {
    func client(_ client: VNCRFBClient, didChangePhase phase: RemoteDesktopPhase, hint: String?)
    func client(_ client: VNCRFBClient, didUpdateFrame image: CGImage?, size: CGSize, desktopName: String?)
    func client(_ client: VNCRFBClient, didUpdateCursor cursor: RemoteCursorInfo?)
    func client(_ client: VNCRFBClient, didReceiveClipboard text: String)
}

final class VNCRFBClient: @unchecked Sendable {
    struct Configuration {
        var host: String
        var port: UInt16
        var password: String
        /// The account name for Apple Remote Desktop authentication (macOS
        /// Screen Sharing); VNC authentication has none.
        var username: String = ""
        var shared: Bool
        var timeout: TimeInterval = 15
        /// Overrides the socket the client talks on — the SSH-tunnel path
        /// hands in a socket to the local forward endpoint.
        var channel: VNCByteChannel?
    }

    private let configuration: Configuration
    weak var delegate: VNCRFBClientDelegate?

    private let framebuffer = VNCFramebuffer()
    private let zlib = VNCZlibStream()
    private var channel: VNCByteChannel?
    private var reader: Thread?
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false
    private var buttonMask: UInt8 = 0
    private var pointerX: UInt16 = 0
    private var pointerY: UInt16 = 0
    private var desktopName = ""
    /// The pixel format rects are decoded with. Starts as the server's
    /// advertised format, becomes `clientRequested` once SetPixelFormat
    /// is on the wire (a conforming server then emits that format).
    private var pixelFormat = VNCPixelFormat.clientRequested
    private var pixelTranslator: ((Data, Int) -> UInt32)?

    private var decodeContext: VNCDecoders.Context {
        VNCDecoders.Context(
            framebuffer: framebuffer,
            pixelTranslator: pixelTranslator ?? { _, _ in 0xFFFF_00FF },
            bytesPerPixel: pixelFormat.bytesPerPixel,
            cpixelByteCount: pixelFormat.cpixelByteCount,
            cpixelPadsAtEnd: !pixelFormat.bigEndian,
            zlib: zlib
        )
    }

    init(configuration: Configuration, delegate: VNCRFBClientDelegate) {
        self.configuration = configuration
        self.delegate = delegate
    }

    // MARK: - Lifecycle

    /// Starts the handshake on a background reader thread.
    func start() {
        let thread = Thread { [self] in
            run()
        }
        thread.name = "me.mizorewww.vnc.\(configuration.host):\(configuration.port)"
        thread.start()
        reader = thread
    }

    /// Ends the session: the socket is interrupted so a blocked read wakes,
    /// and the reader exits.
    func stop() {
        stateLock.withLock { stopped = true }
        (channel as? VNCSocket)?.interrupt()
        channel?.close()
    }

    private func isStopped() -> Bool {
        stateLock.withLock { stopped }
    }

    private func report(phase: RemoteDesktopPhase, hint: String? = nil) {
        delegate?.client(self, didChangePhase: phase, hint: hint)
    }

    // MARK: - The session

    /// The reader-thread entry point; `internal` so tests can drive it
    /// synchronously over a scripted memory channel.
    func run() {
        report(phase: .connecting("Reaching \(configuration.host)"), hint: "Connecting…")
        do {
            let channel: VNCByteChannel = try configuration.channel
                ?? VNCSocket.connect(host: configuration.host, port: configuration.port, timeout: configuration.timeout)
            self.channel = channel
            try handshake(over: channel)
            report(phase: .connected, hint: nil)
            try readLoop(over: channel)
            if !isStopped() {
                report(phase: .closed("The server closed the connection."))
            }
        } catch let error as RemoteDesktopFailure {
            report(phase: .failed(error.message))
        } catch let error as VNCStreamError {
            if isStopped() { return }
            switch error {
            case .endOfStream:
                report(phase: .closed("The server closed the connection."))
            case let .failed(reason):
                report(phase: .failed(reason))
            }
        } catch let error as VNCDecodeError {
            report(phase: .failed("The server sent data this client cannot read (\(describe(error)))."))
        } catch {
            if !isStopped() {
                report(phase: .failed(error.localizedDescription))
            }
        }
    }

    private func describe(_ error: VNCDecodeError) -> String {
        switch error {
        case let .unsupportedEncoding(encoding): return "encoding \(encoding)"
        case let .malformed(reason): return reason
        }
    }

    // MARK: Handshake

    private func handshake(over channel: VNCByteChannel) throws {
        // Version banner.
        let banner = try channel.read(exactly: 12)
        guard let version = VNCWire.parseBanner(banner) else {
            throw RemoteDesktopFailure("The server is not speaking RFB.")
        }
        // Answer the best version both support: 3.3 only if the server is
        // that old; otherwise 3.8 (the failure-reason string exists only
        // on 3.8).
        let answerMinor = version.minor < 8 ? version.minor : 8
        try send(VNCWire.banner(major: 3, minor: answerMinor), over: channel)
        let protocol38 = answerMinor >= 8

        // Security negotiation.
        report(phase: .authenticating, hint: "Authenticating…")
        var offered: [UInt8] = []
        if version.minor == 3 {
            // 3.3 sends one u32 type directly; 0 means the connection is
            // refused outright and a reason string follows.
            let type = try channel.read(exactly: 4).readU32BE(at: 0).clampedToUInt8()
            if type == 0 {
                let reason = try readReasonString(over: channel)
                throw RemoteDesktopFailure(reason ?? "The server refused the connection.")
            }
            offered = [type]
        } else {
            let count = Int(try channel.read(exactly: 1)[0])
            guard count > 0 else {
                let reason = try readReasonString(over: channel)
                throw RemoteDesktopFailure(reason ?? "The server refused the connection.")
            }
            offered = Array(try channel.read(exactly: count))
        }

        let selected = try chooseSecurityType(from: offered)

        if version.minor != 3 {
            try send(Data([selected]), over: channel)
        }

        switch selected {
        case VNCWire.SecurityType.vncAuth.rawValue:
            let challenge = Array(try channel.read(exactly: 16))
            guard let response = VNCDES.encryptChallenge(challenge, password: configuration.password) else {
                throw RemoteDesktopFailure("Could not answer the VNC authentication challenge.")
            }
            try send(Data(response), over: channel)
        case VNCWire.SecurityType.appleRemoteDesktop.rawValue:
            let parameters = try VNCAppleAuth.readParameters(over: channel)
            let response = try VNCAppleAuth.response(
                to: parameters,
                username: configuration.username,
                password: configuration.password
            )
            try send(response, over: channel)
        default:
            break
        }

        // SecurityResult: u32, 0 on success. For 3.8 a failure carries a
        // reason string; for 3.3 and 3.7 it does not.
        let result = try channel.read(exactly: 4).readU32BE(at: 0)
        if result != 0 {
            let reason = protocol38 ? try readReasonString(over: channel) : nil
            throw RemoteDesktopFailure(reason ?? "The VNC server rejected the credentials.")
        }

        // ClientInit / ServerInit.
        try send(VNCWire.clientInit(shared: configuration.shared), over: channel)
        report(phase: .connecting("Negotiating the framebuffer"), hint: "Negotiating…")
        // width(2) height(2) pixelformat(16) nameLen(4) + name
        var initData = try channel.read(exactly: 24)
        let nameLength = Int(initData.readU32BE(at: 20))
        if nameLength > 0 {
            initData.append(try channel.read(exactly: nameLength))
        }
        guard let serverInit = VNCWire.parseServerInit(data: initData) else {
            throw RemoteDesktopFailure("The server sent a malformed init message.")
        }
        desktopName = serverInit.desktopName
        guard serverInit.pixelFormat.translator() != nil else {
            throw RemoteDesktopFailure("The server's pixel format (\(serverInit.pixelFormat.bitsPerPixel)bpp, depth \(serverInit.pixelFormat.depth)) is unsupported.")
        }
        framebuffer.resize(width: serverInit.width, height: serverInit.height)

        // From here on the server emits `clientRequested` pixels.
        pixelFormat = .clientRequested
        pixelTranslator = VNCPixelFormat.clientRequested.translator()
        try send(VNCWire.setPixelFormat(.clientRequested), over: channel)
        try send(VNCWire.setEncodings(VNCWire.clientEncodings), over: channel)
        requestUpdate(incremental: false)
        delegate?.client(self, didUpdateFrame: nil, size: framebuffer.size, desktopName: desktopName)
    }

    /// None if the server allows it; Apple authentication when there is a
    /// user name to give (macOS offers it beside a VNC password); else the
    /// VNC password.
    private func chooseSecurityType(from offered: [UInt8]) throws -> UInt8 {
        let none = VNCWire.SecurityType.none.rawValue
        let vncAuth = VNCWire.SecurityType.vncAuth.rawValue
        let apple = VNCWire.SecurityType.appleRemoteDesktop.rawValue
        if offered.contains(none) { return none }
        let hasUser = !configuration.username.isEmpty
        if offered.contains(apple), hasUser {
            guard !configuration.password.isEmpty else {
                throw RemoteDesktopFailure("The Mac asks for the password of \(configuration.username). Set one on the server, or on its identity.")
            }
            return apple
        }
        if offered.contains(vncAuth) {
            guard !configuration.password.isEmpty else {
                throw RemoteDesktopFailure("The VNC server asks for a password. Set one on the server, or on the identity it falls back to.")
            }
            return vncAuth
        }
        if offered.contains(apple) {
            throw RemoteDesktopFailure("The Mac asks for a user name and password. Set the VNC user name on the server, or give it an identity.")
        }
        throw RemoteDesktopFailure("The server offers no supported security type (\(offered.map(String.init).joined(separator: ", "))).")
    }

    /// A 3.8 reason string: u32 length + UTF-8 text; 3.3/3.7 send nothing.
    private func readReasonString(over channel: VNCByteChannel) throws -> String? {
        let length = Int(try channel.read(exactly: 4).readU32BE(at: 0))
        guard length > 0, length < 64 * 1024 else { return nil }
        return String(data: try channel.read(exactly: length), encoding: .utf8)
    }

    // MARK: Read loop

    private func readLoop(over channel: VNCByteChannel) throws {
        while true {
            if isStopped() { return }
            let type = try channel.read(exactly: 1)[0]
            switch VNCWire.ServerMessageType(rawValue: type) {
            case .framebufferUpdate:
                try handleUpdate(over: channel)
            case .setColourMapEntries:
                // pad(1) firstColor(2) count(2) + count * 6 bytes
                let header = try channel.read(exactly: 5)
                let count = Int(header.readU16BE(at: 3))
                _ = try channel.read(exactly: count * 6)
            case .bell:
                break
            case .serverCutText:
                _ = try channel.read(exactly: 3) // padding
                let length = Int(try channel.read(exactly: 4).readU32BE(at: 0))
                guard length < 16 * 1024 * 1024 else { return }
                let text = String(data: try channel.read(exactly: length), encoding: .isoLatin1) ?? ""
                delegate?.client(self, didReceiveClipboard: text)
            case nil:
                // Unknown message: there is no way to know its length, so
                // the stream is unrecoverable.
                throw RemoteDesktopFailure("The server sent an unknown message type \(type).")
            }
        }
    }

    private func handleUpdate(over channel: VNCByteChannel) throws {
        _ = try channel.read(exactly: 1) // padding
        let count = Int(try channel.read(exactly: 2).readU16BE(at: 0))
        let context = decodeContext
        var sizeChanged = false
        for _ in 0 ..< count {
            let headerData = try channel.read(exactly: VNCWire.RectangleHeader.wireLength)
            guard let header = VNCWire.RectangleHeader(wire: headerData) else {
                throw RemoteDesktopFailure("The server sent a malformed rectangle.")
            }
            switch VNCWire.Encoding(rawValue: header.encoding) {
            case .desktopSize:
                framebuffer.resize(width: header.width, height: header.height)
                sizeChanged = true
            case .cursor:
                let cursor = try VNCDecoders.decodeCursor(header, from: channel, context: context)
                delegate?.client(self, didUpdateCursor: cursor)
            default:
                try VNCDecoders.decode(header, from: channel, context: context)
            }
        }
        let image = framebuffer.makeImage()
        delegate?.client(self, didUpdateFrame: image, size: framebuffer.size, desktopName: sizeChanged ? desktopName : nil)
        requestUpdate(incremental: true)
    }

    // MARK: - Outbound messages (called from the UI thread)

    private func send(_ data: Data, over channel: VNCByteChannel) throws {
        try writeLock.withLock { try channel.write(data) }
    }

    private func send(_ data: Data) throws {
        guard let channel else { return }
        try send(data, over: channel)
    }

    func requestUpdate(incremental: Bool) {
        let size = framebuffer.size
        guard size.width > 0, size.height > 0 else { return }
        try? send(VNCWire.framebufferUpdateRequest(
            incremental: incremental, x: 0, y: 0,
            width: UInt16(min(Int(size.width), Int(UInt16.max))),
            height: UInt16(min(Int(size.height), Int(UInt16.max)))
        ))
    }

    /// The RFB button bit for a mouse button.
    private func buttonBit(_ button: MouseButton) -> UInt8 {
        switch button {
        case .left: return 1 << 0
        case .middle: return 1 << 1
        case .right: return 1 << 2
        // Wheels go through sendScroll; extra buttons have no RFB type.
        case .back, .forward: return 0
        }
    }

    /// Normalized view coordinates -> framebuffer pixel coordinates.
    private func pixelPoint(normalizedX: Double, normalizedY: Double) -> (x: UInt16, y: UInt16) {
        let size = framebuffer.size
        let x = UInt16((normalizedX * Double(size.width)).clamped(to: 0 ... Double(max(size.width - 1, 0))))
        let y = UInt16((normalizedY * Double(size.height)).clamped(to: 0 ... Double(max(size.height - 1, 0))))
        return (x, y)
    }

    func pointerMoved(normalizedX: Double, normalizedY: Double) {
        let point = pixelPoint(normalizedX: normalizedX, normalizedY: normalizedY)
        pointerX = point.x
        pointerY = point.y
        try? send(VNCWire.pointerEvent(buttonMask: buttonMask, x: point.x, y: point.y))
    }

    func pointerButton(_ button: MouseButton, isDown: Bool, normalizedX: Double, normalizedY: Double) {
        let point = pixelPoint(normalizedX: normalizedX, normalizedY: normalizedY)
        pointerX = point.x
        pointerY = point.y
        let bit = buttonBit(button)
        if isDown { buttonMask |= bit } else { buttonMask &= ~bit }
        try? send(VNCWire.pointerEvent(buttonMask: buttonMask, x: point.x, y: point.y))
    }

    /// A wheel event is a button press-release pair per tick.
    func scrolled(deltaX: Double, deltaY: Double, normalizedX: Double, normalizedY: Double) {
        let point = pixelPoint(normalizedX: normalizedX, normalizedY: normalizedY)
        pointerX = point.x
        pointerY = point.y

        func wheelTicks(_ delta: Double, upBit: UInt8, downBit: UInt8) {
            let ticks = min(Int(abs(delta).rounded()), 10)
            let bit: UInt8 = delta > 0 ? upBit : downBit
            for _ in 0 ..< ticks {
                try? send(VNCWire.pointerEvent(buttonMask: buttonMask | bit, x: point.x, y: point.y))
                try? send(VNCWire.pointerEvent(buttonMask: buttonMask, x: point.x, y: point.y))
            }
        }
        // RFB: bit3=scroll up, bit4=down, bit5=left, bit6=right.
        wheelTicks(deltaY, upBit: 1 << 3, downBit: 1 << 4)
        wheelTicks(deltaX, upBit: 1 << 6, downBit: 1 << 5)
    }

    func keyEvent(keyCode: UInt16, keySym: UInt32?, characters: String, isDown: Bool) {
        let sym = keySym ?? VNCKeySyms.keySym(forKeyCode: keyCode, characters: characters)
        guard let sym else { return }
        try? send(VNCWire.keyEvent(down: isDown, keySym: sym))
    }

    func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            guard let sym = VNCKeySyms.keySym(forCharacter: String(scalar)) else { continue }
            try? send(VNCWire.keyEvent(down: true, keySym: sym))
            try? send(VNCWire.keyEvent(down: false, keySym: sym))
        }
    }

    func setClipboard(_ text: String) {
        try? send(VNCWire.clientCutText(text))
    }
}

private extension UInt32 {
    func clampedToUInt8() -> UInt8 {
        UInt8(Swift.min(self, UInt32(UInt8.max)))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
