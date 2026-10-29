//
//  VNCRFBDriver.swift
//  CatusshModule
//
//  The RemoteDesktopDriver for VNC: owns the optional SSH tunnel and the
//  RFB client, wires the client's reports into the session, and turns the
//  session's input calls into RFB messages.
//

import CoreGraphics
import Foundation

final class VNCRFBDriver: RemoteDesktopDriver, @unchecked Sendable {
    private let machine: RDMachine
    private weak var session: RemoteDesktopSession?
    private var client: VNCRFBClient?
    private var tunnel: VNCSSHTunnel?
    private var worker: Thread?
    private let stateLock = NSLock()
    private var stopped = false
    /// Cursor + framebuffer state, touched by both the input calls (main
    /// actor) and the client delegate (reader thread).
    private let cursorLock = NSLock()
    /// The last cursor shape reported; its x,y hold the hotspot in pixels.
    private var cursorShape: RemoteCursorInfo?
    /// The pointer's last normalized position; the remote cursor follows
    /// it (the host does not report cursor moves itself).
    private var pointerX = 0.0
    private var pointerY = 0.0
    /// The remote framebuffer's pixel size, learned from frame updates.
    private var framebufferSize: CGSize = .zero

    init(machine: RDMachine, session: RemoteDesktopSession) {
        self.machine = machine
        self.session = session
    }

    // MARK: - RemoteDesktopDriver

    func start(session: RemoteDesktopSession) {
        stateLock.withLock { stopped = false }
        let thread = Thread { [self] in
            bootstrap()
        }
        thread.name = "me.mizorewww.vnc-driver.\(machine.remoteAddress)"
        thread.start()
        worker = thread
    }

    func stop() {
        stateLock.withLock { stopped = true }
        tunnel?.stop()
        client?.stop()
    }

    private func isStopped() -> Bool {
        stateLock.withLock { stopped }
    }

    private func bootstrap() {
        var channel: VNCByteChannel?
        if machine.vncOverSSH {
            reportPhase(.connecting("Opening the SSH tunnel"), hint: "Opening SSH tunnel…")
            let tunnel = VNCSSHTunnel(
                machine: machine,
                targetPort: UInt16(machine.vncPort) ?? 5900
            )
            self.tunnel = tunnel
            switch tunnel.start() {
            case let .failure(error):
                reportPhase(.failed(error.message))
                return
            case let .success(localPort):
                do {
                    channel = try VNCSocket.connect(host: "127.0.0.1", port: localPort, timeout: 10)
                } catch {
                    reportPhase(.failed("The SSH tunnel opened but the VNC port could not be dialed."))
                    return
                }
            }
            guard !isStopped() else { return }
        }

        let identity = CatusshStore.shared.workerAssociatedIdentity(for: machine)
        let client = VNCRFBClient(
            configuration: .init(
                host: machine.remoteAddress,
                port: UInt16(machine.vncPort) ?? 5900,
                password: machine.resolvedVNCPassword(identity: identity),
                shared: machine.vncShared,
                timeout: max(TimeInterval(CatusshStore.shared.workerTimeoutNumber.intValue), 10),
                channel: channel
            ),
            delegate: self
        )
        self.client = client
        client.start()
    }

    private func reportPhase(_ phase: RemoteDesktopPhase, hint: String? = nil) {
        session?.reportPhase(phase, hint: hint)
    }

    // MARK: - Input

    func sendPointerMove(normalizedX: Double, normalizedY: Double) {
        client?.pointerMoved(normalizedX: normalizedX, normalizedY: normalizedY)
        updateCursorPosition(normalizedX: normalizedX, normalizedY: normalizedY)
    }

    func sendPointerButton(_ button: MouseButton, isDown: Bool, normalizedX: Double, normalizedY: Double) {
        updateCursorPosition(normalizedX: normalizedX, normalizedY: normalizedY)
        client?.pointerButton(button, isDown: isDown, normalizedX: normalizedX, normalizedY: normalizedY)
    }

    func sendScroll(deltaX: Double, deltaY: Double, normalizedX: Double, normalizedY: Double) {
        updateCursorPosition(normalizedX: normalizedX, normalizedY: normalizedY)
        client?.scrolled(deltaX: deltaX, deltaY: deltaY, normalizedX: normalizedX, normalizedY: normalizedY)
    }

    func sendKey(keyCode: UInt16, keySym: UInt32?, characters: String, isDown: Bool) {
        client?.keyEvent(keyCode: keyCode, keySym: keySym, characters: characters, isDown: isDown)
    }

    func sendText(_ text: String) {
        client?.typeText(text)
    }

    func sendClipboard(_ text: String) {
        client?.setClipboard(text)
    }

    func selectDisplay(_: Int) {
        // Standard RFB has no display switching; pseudo-encodings such as
        // ExtendedDesktopSize cover resizing, not monitor selection.
    }

    func updateQuality(fps _: Int, quality _: Int) {
        // The RFB wire has no quality knob; encodings are negotiated once.
    }

    func requestKeyframeOrRefresh() {
        // A non-incremental update request asks for the whole framebuffer.
        client?.requestUpdate(incremental: false)
    }

    /// Records the pointer position and re-emits the cursor overlay at
    /// pointer − hotspot, all in normalized framebuffer coordinates.
    private func updateCursorPosition(normalizedX: Double, normalizedY: Double) {
        let cursor = cursorLock.withLock { () -> RemoteCursorInfo? in
            pointerX = normalizedX
            pointerY = normalizedY
            return cursorAtCurrentPointer()
        }
        if let cursor { session?.reportCursor(cursor) }
    }

    /// The cursor at the tracked pointer position, or nil if there is no
    /// shape or framebuffer yet. Call while `cursorLock` is held.
    private func cursorAtCurrentPointer() -> RemoteCursorInfo? {
        guard let shape = cursorShape,
              framebufferSize.width > 0, framebufferSize.height > 0 else { return nil }
        var cursor = shape
        // shape.x/shape.y are the hotspot in cursor-image pixels, so the
        // image's top-left lands at pointer − hotspot (all normalized).
        cursor.x = pointerX - shape.x / framebufferSize.width
        cursor.y = pointerY - shape.y / framebufferSize.height
        return cursor
    }
}

// MARK: - VNCRFBClientDelegate

extension VNCRFBDriver: VNCRFBClientDelegate {
    func client(_: VNCRFBClient, didChangePhase phase: RemoteDesktopPhase, hint: String?) {
        reportPhase(phase, hint: hint)
    }

    func client(_: VNCRFBClient, didUpdateFrame image: CGImage?, size: CGSize, desktopName: String?) {
        cursorLock.withLock { framebufferSize = size }
        session?.reportFrame(image, size: size, desktopName: desktopName)
    }

    func client(_: VNCRFBClient, didUpdateCursor cursor: RemoteCursorInfo?) {
        let positioned = cursorLock.withLock { () -> RemoteCursorInfo? in
            cursorShape = cursor
            return cursorAtCurrentPointer()
        }
        if let positioned { session?.reportCursor(positioned) }
    }

    func client(_: VNCRFBClient, didReceiveClipboard text: String) {
        session?.reportRemoteClipboard(text)
    }
}
