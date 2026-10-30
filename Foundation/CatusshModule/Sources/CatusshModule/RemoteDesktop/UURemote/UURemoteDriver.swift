//
//  UURemoteDriver.swift
//  CatusshModule
//
//  The RemoteDesktopDriver that runs a native UU Remote session end-to-end:
//  REST room bootstrap, Socket.IO signaling, a WebKit-hosted RTCPeerConnection,
//  the five data channels, RTP video decode, and input/terminal/port-mapping.
//  Mirrors /tmp/uu-refs/uu-remote-linux/src/viewer/{session,rtc,wire,input}.rs
//  and /tmp/uu-refs/uurc-web/backend/src/services/remoteControlService.ts.
//

import Foundation
import ImageIO
import os
import WebKit

public enum UUDriverError: Error, Sendable {
    case notLoggedIn
    case missingDeviceID
    case roomJoinFailed(String)
    case signalConnectFailed(String)
    case controlRejected(Int, String)
    case webkitUnavailable
    case timeout(String)
}

/// A Sendable box for the `[String: Any]` JSON the signal/RTC layers exchange.
private struct UUJsonBox: @unchecked Sendable {
    let dict: [String: Any]
    init(_ dict: [String: Any]) { self.dict = dict }
}

/// The RemoteDesktopDriver that speaks native UU Remote.
public final class UURemoteDriver: RemoteDesktopDriver, @unchecked Sendable {
    private let session: RemoteDesktopSession
    private let signalClient = UURemoteSignalingClient()
    private let videoAssembler = UURTPVideoAssembler()
    private let videoDecoder = UURemoteRTPVideoDecoder()
    /// Encoded WebRTC frames are decoded here, in arrival order, off the
    /// main thread.
    private let decodeQueue = DispatchQueue(label: "me.mizorewww.uu.encoded-decode", qos: .userInteractive)
    private let encodedDecoder = UURemoteRTPVideoDecoder()
    /// From the receiver's stats; the host has always sent H.265 so far.
    private var encodedCodec = "H265"
    private let portMapping: UURemotePortMappingTunnel

    private var peer: UURTCPeerConnection?
    private var roomConfig: UURoomConfig?
    private var deviceID = ""
    private var controlChannelOpen = false
    private var binaryChannelOpen = false
    private var fileChannelOpen = false
    private var streamerChannelOpen = false
    private var textChannelOpen = false

    private var outboundSequence: UInt64 = 0
    private let outboundLock = NSLock()

    // MARK: Session routing ids (upstream `Peer::new` arguments)

    /// The `app_control_id` we mint per session — the host echoes it in the
    /// control ack and every SOAC route check.
    private var appControlID = ""
    /// Our ICE session id; the cloud assigns the authoritative one in the
    /// control ack (upstream keeps whichever the ack returns).
    private var iceID = ""
    /// The host's route id — every outbound SOAC is `{client_id: this}`.
    private var remoteClientID = ""
    private var answered = false
    private var earlyCandidates: [[String: Any]] = []

    /// Resolved at connect time from the account's device list: the
    /// `kbd_press` payload wants Windows VK values for Windows hosts and
    /// macOS virtual keycodes for Mac hosts. Unknown (assist joins)
    /// defaults to Windows, the majority case for UU Remote.
    private var targetIsWindows = true
    private var heartbeatTask: Task<Void, Never>?
    private var videoRequestTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?
    private var closed = false
    /// `stop()` must not overwrite a terminal `.failed` phase with `.closed`.
    private var reportedTerminalPhase = false
    private var requestedDisplayApplied = false

    /// What the connection is for: a desktop streams the screen; a terminal
    /// connection carries terminals (and port mappings) and no video.
    public enum Purpose: Sendable { case desktop, terminal }
    public var purpose: Purpose = .desktop

    /// Terminals open on this connection, by TERM session id; their frames
    /// go to these. Main thread.
    private var terminalSinks: [UInt32: (UUTerminalFrame) -> Void] = [:]
    /// Terminals closed here: the host's late frames for them go nowhere.
    private var closedTerminalIDs: Set<UInt32> = []
    private var nextTerminalID: UInt32 = 1

    /// Control and binary channels are both open: terminals can start.
    public var isReady: Bool { controlChannelOpen && binaryChannelOpen && !closed }
    public var isClosed: Bool { closed }

    public required init(session: RemoteDesktopSession) {
        self.session = session
        let tunnel = UURemotePortMappingTunnel(sendEnvelope: { _ in })
        portMapping = tunnel
        tunnel.setSendEnvelope { [weak self] envelope in
            self?.sendFileChannel(envelope)
        }
    }

    // MARK: - RemoteDesktopDriver

    public func start(session: RemoteDesktopSession) {
        Task { await connect() }
    }

    public func stop() {
        closed = true
        connectTimeoutTask?.cancel()
        heartbeatTask?.cancel()
        videoRequestTask?.cancel()
        portMapping.shutdown()
        UURemotePortMappingTunnelProvider.shared.unregister(for: deviceID)
        Task { await signalClient.disconnect() }
        // Capture the peer before clearing it: `self?.peer` inside the
        // MainActor task would already be nil and closeAll() would never
        // run, leaving the WKWebView peer alive until deinit.
        let currentPeer = peer
        peer = nil
        Task { @MainActor in
            _ = try? await currentPeer?.evaluate("closeAll()") as String?
        }
        if !reportedTerminalPhase {
            session.reportPhase(.closed(nil), hint: "UU Remote session ended")
        }
    }

    /// Desktop input is a bare JSON *string* on CONTROL_DATA_CHANNEL (the
    /// upstream `send_input` path); protobuf envelopes are only for
    /// SimpleAction / RpcRequest control messages.
    public func sendPointerMove(normalizedX: Double, normalizedY: Double) {
        guard controlChannelOpen else { return }
        sendControlChannel(UUControlProtocol.mouseMoveAbsolute(x: normalizedX, y: normalizedY))
    }

    public func sendPointerButton(_ button: MouseButton, isDown: Bool, normalizedX: Double, normalizedY: Double) {
        guard controlChannelOpen else { return }
        let uuButton: UUControlProtocol.Button = switch button {
        case .left: .left
        case .middle: .middle
        case .right: .right
        case .back: .back
        case .forward: .forward
        }
        sendControlChannel(UUControlProtocol.mouseButton(uuButton, isDown: isDown))
    }

    public func sendScroll(deltaX: Double, deltaY: Double, normalizedX: Double, normalizedY: Double) {
        guard controlChannelOpen else { return }
        // Upstream feeds browser wheel deltas (~±60 per notch at desktop
        // scale); our contract is wheel ticks, so scale a notch back out.
        // Positive `delta_y` scrolls up on both sides of the wire.
        sendControlChannel(UUControlProtocol.mouseScroll(dx: Int32(deltaX * 60), dy: Int32(deltaY * 60)))
    }

    public func sendKey(keyCode: UInt16, keySym: UInt32?, characters: String, isDown: Bool) {
        guard controlChannelOpen else { return }
        // `keyCode` arrives as a Carbon virtual keycode — the same code
        // space a macOS target takes. Windows targets get the matching VK.
        let key = targetIsWindows
            ? (RemoteDesktopKeymap.windowsVKForCarbon[keyCode] ?? Int32(keyCode))
            : Int32(keyCode)
        sendControlChannel(UUControlProtocol.keyPress(key: key, isDown: isDown, windowsTarget: targetIsWindows))
    }

    public func sendText(_ text: String) {
        guard controlChannelOpen else { return }
        sendControlChannel(UUControlProtocol.textInput(text))
    }

    /// Clipboard V3: `RpcRequest` case 10 `ClipboardTextChangeRequest`
    /// `{1: formatId, 2: text}` on TEXT_DATA_CHANNEL, where the host's
    /// clipboard bridge lives (upstream `viewer/clipboard.rs`).
    public func sendClipboard(_ text: String) {
        guard textChannelOpen else { return }
        sendTextChannel(UUControlProtocol.clipboardTextChangeRequest(
            requestID: nextOutboundSequence(),
            text: String(text.prefix(30 * 1024))
        ))
    }

    /// SimpleAction `restart_capture` (8) with `{"screen_id":N}` — the way
    /// the official viewer switches the captured display.
    public func selectDisplay(_ displayID: Int) {
        guard controlChannelOpen else { return }
        sendControlChannel(UUControlProtocol.envelope(
            sequence: nextOutboundSequence(),
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            fieldNumber: UUControlField.simpleAction,
            body: UUControlProtocol.simpleAction(
                action: UUSimpleActionType.restartCapture,
                argsJSON: #"{"screen_id":\#(displayID)}"#
            )
        ))
    }

    /// CaptureSettingRequest (RpcRequest case 2): field 1 fps *option
    /// index*, field 18 raw fpsCount, field 2 quality.
    public func updateQuality(fps: Int, quality: Int) {
        guard controlChannelOpen else { return }
        sendControlChannel(UUControlProtocol.captureSettingRequest(
            requestID: nextOutboundSequence(),
            rawFPS: Int32(fps),
            quality: quality > 0 ? Int32(quality) : nil
        ))
    }

    public func requestKeyframeOrRefresh() {
        guard controlChannelOpen else { return }
        sendControlChannel(UUControlProtocol.sendVideoTrackRequest(requestID: nextOutboundSequence()))
    }

    // MARK: - Connection flow

    private func connect() async {
        guard !closed else { return }
        session.reportPhase(.connecting("Starting UU Remote session"), hint: "Resolving device…")

        deviceID = session.machine.uuDeviceID.isEmpty ? session.machine.remoteAddress : session.machine.uuDeviceID
        guard !deviceID.isEmpty else {
            reportTerminal(.failed("UU Remote device ID is missing."), hint: "Bind a device first")
            return
        }

        if let device = await MainActor.run(body: {
            UURemoteAccountStore.shared.devices.first(where: { $0.deviceID == deviceID })
        }) {
            targetIsWindows = device.platform != 4
        }

        UURemotePortMappingTunnelProvider.shared.register(portMapping, for: deviceID)

        do {
            // Room bootstrap, once the saved account is in the client.
            await UURemoteAccountStore.shared.ready()
            session.reportPhase(.connecting("Joining room"), hint: "Joining UU Remote room…")
            let roomConfig: UURoomConfig
            if !session.machine.uuAssistID.isEmpty {
                roomConfig = try await UURemoteAccountStore.shared.apiClient.joinShareByCode(
                    connectID: session.machine.uuAssistID,
                    code: session.machine.uuAssistCode
                )
            } else {
                roomConfig = try await UURemoteAccountStore.shared.apiClient.roomJoinByDevice(deviceID, forceJoin: true)
            }
            self.roomConfig = roomConfig
            session.reportHint("Signal servers: \(roomConfig.signalServers.joined(separator: ", "))")

            // Signaling
            session.reportPhase(.connecting("Opening signal channel"), hint: "Connecting to signal server…")
            await signalClient.setOnSignalEvent { [weak self] event, args, _ in
                self?.handleSignalEvent(event, args: args)
            }
            await signalClient.setOnSOAC { [weak self] soac in
                let box = UUJsonBox(soac)
                Task { await self?.handleSOAC(box.dict) }
            }
            try await signalClient.connect(roomConfig: roomConfig)
            session.reportHint("Signal channel open")

            // Control emit — the upstream viewer asks to be controlled
            // *before* it knows the ICE servers; the ack carries them.
            session.reportPhase(.connecting("Requesting control"), hint: "Asking host to control…")
            appControlID = UUID().uuidString
            iceID = Self.randomHexID(byteCount: 16)
            let options = await makeConnectOptions(capture: purpose == .terminal ? UUCaptureType.terminal : UUCaptureType.desktop)
            let ackData = try await signalClient.emitControl(
                appControlID: appControlID,
                connectOptions: options,
                streamerData: Self.streamerData(
                    controlID: appControlID,
                    fps: session.machine.uuFPS,
                    quality: session.machine.uuQuality
                ),
                timeout: 15
            )
            let result = try Self.controlAckResult(ackData, appControlID: appControlID)
            if let code = result["code"] as? Int, code != 0 {
                throw UUDriverError.controlRejected(code, result["msg"] as? String ?? "control rejected")
            }
            remoteClientID = result["client_id"] as? String ?? ""
            // Observed live upstream: the cloud assigns the session ice_id
            // in this ack rather than echoing ours.
            if let assigned = result["ice_id"] as? String, !assigned.isEmpty, assigned.count <= 128 {
                iceID = assigned
            }
            let iceServers = Self.iceServers(from: result)
            let forceRelay = result["force_relay"] as? Bool ?? false
            session.reportHint("Control request accepted")

            // WebRTC — configured from the ack's ICE servers.
            session.reportPhase(.connecting("Creating peer connection"), hint: "Starting WebRTC…")
            try await setupPeerConnection(iceServers: iceServers, forceRelay: forceRelay)

            // The viewer always offers (upstream session.rs); the offer's
            // SOAC envelope is {client_id, data:{type:"offer",…}}.
            session.reportPhase(.connecting("Negotiating media"), hint: "Sending SDP offer…")
            try await sendWebRTCOffer(iceRestart: false)

            // Timeout watchdog
            connectTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                // The control channel may open before this task exists, so
                // its cancel() can come too early: look at the state too.
                guard let self, !self.closed, !self.controlChannelOpen else { return }
                self.reportTerminal(.failed("UU Remote session timed out waiting for the host."))
                self.stop()
            }
        } catch {
            reportTerminal(.failed(error.localizedDescription), hint: "UU Remote connect failed")
            stop()
        }
    }

    /// Unpacks `["success", {result}]` (upstream `read_event("success")`);
    /// verifies the returned app_control_id belongs to this session.
    private static func controlAckResult(_ ackData: Data, appControlID: String) throws -> [String: Any] {
        guard let array = try? JSONSerialization.jsonObject(with: ackData) as? [Any],
              array.count >= 2,
              (array[0] as? String) == "success",
              let result = array[1] as? [String: Any]
        else { throw UUDriverError.controlRejected(-1, "control ack malformed") }
        if let returned = result["app_control_id"] as? String, returned != appControlID {
            throw UUDriverError.controlRejected(-1, "control acknowledgement belongs to another session")
        }
        return result
    }

    /// ICE servers from the control ack (`result.iceServers[]` with
    /// `urls`/`username`/`credential`), normalized for WebKit.
    private static func iceServers(from result: [String: Any]) -> [[String: Any]] {
        guard let list = result["iceServers"] as? [[String: Any]] else { return [] }
        return list.compactMap { server in
            var entry: [String: Any] = [:]
            switch server["urls"] {
            case let urls as [String]: entry["urls"] = urls
            case let url as String: entry["urls"] = [url]
            case let urls as [Any]: entry["urls"] = urls.compactMap { $0 as? String }
            default: return nil
            }
            if let username = server["username"] as? String { entry["username"] = username }
            if let credential = server["credential"] as? String { entry["credential"] = credential }
            return entry
        }
    }

    private static func randomHexID(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `streamer_data` (a JSON *string* on the wire) of
    /// `{control_id, device_capability:{display_info, ice_id,
    /// video_codec_capability}}` — mirrors `Shape.control` upstream.
    private static func streamerData(controlID: String, fps: Int, quality: Int) -> [String: Any] {
        let codecs = quality >= 2 ? [1, 2] : [1]
        var capability: [[String: Any]] = []
        for codec in codecs {
            for chroma in [1, 3] {
                capability.append([
                    "video_codec": codec,
                    "chroma_sampling": chroma,
                    "codec_impl": 34, // observed official Mac viewer value
                    "bit_depth": 8,
                    "width": 3840,
                    "height": 2160,
                ])
            }
        }
        return [
            "control_id": controlID,
            "device_capability": [
                "display_info": [["id": 1, "fps": fps, "type": 0, "hdr": 0]],
                "ice_id": "",
                "video_codec_capability": capability,
            ],
        ]
    }

    private func makeConnectOptions(capture: Int) async -> Data {
        var options = UUConnectOptions()
        options.captureType = capture
        // The official viewer sends u64::MAX type_value for capture 1 and 8.
        if capture == UUCaptureType.desktop || capture == UUCaptureType.terminal {
            options.typeValue = UInt64.max
        }
        options.deviceID = await MainActor.run { UURemoteAccountStore.shared.credentials.deviceID }
        options.clientType = UUClientType.mac
        options.clientVersion = "4.42.0"
        options.controlConnectType = UUControlConnectType.normal
        // Decoder caps: every supported codec × chroma, like upstream's
        // `video_preferences` expansion.
        let codecs: [Int32] = session.machine.uuQuality >= 2 ? [2, 1] : [1]
        for codec in codecs {
            for chroma in [Int32(1), 3] {
                options.decoderCapList.append(UUDecoderCap(
                    fps: Int32(session.machine.uuFPS),
                    codec: codec,
                    width: 3840,
                    height: 2160,
                    chroma: capture == UUCaptureType.desktop ? chroma : 0
                ))
            }
        }
        if capture == UUCaptureType.desktop {
            var params = UUCaptureParams()
            params.fpsTier = UUFpsTier.encode(rawFPS: session.machine.uuFPS)
            params.videoQuality = session.machine.uuQuality
            params.chooseResolutionType = 2 // FOLLOW_LOCAL
            params.localResolution = UUScreenResolution(width: 1920, height: 1080)
            params.chooseResolution = UUScreenResolution() // upstream sends an empty message
            params.chromaFormat = UUChromaFormat.c420 // 4:4:4 is requested later on CONTROL
            params.enableHDR = true
            params.fpsCount = Int32(session.machine.uuFPS)
            options.captureParams = params
            for mode in [UUVirtualDisplayMode(width: 1920, height: 1080, fps: Int32(session.machine.uuFPS))] {
                options.virtualDisplayModes.append(mode)
            }
            options.virtualDisplayInitResolution = UUScreenResolution(width: 1920, height: 1080)
            options.featureFlags = UUViewerFeatureFlags.make(clipboardEnabled: true)
        }
        return options.encode()
    }

    private func setupPeerConnection(iceServers: [[String: Any]], forceRelay: Bool) async throws {
        let peer = await MainActor.run { UURTCPeerConnection() }
        self.peer = peer
        try await peer.waitReady()
        let serversJSON = (try? JSONSerialization.data(withJSONObject: iceServers))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        _ = try await peer.evaluate(
            "makePeer(\(serversJSON), \(forceRelay ? "true" : "false"))"
        ) as String?
        // Where the page runs in a helper, the helper ending ends the session.
        await peer.setFailureHandler { [weak self] reason in
            guard let self, !self.closed else { return }
            self.reportTerminal(.failed(reason))
            self.stop()
        }

        await peer.setCandidateHandler { [weak self] candidate in
            let box = UUJsonBox(candidate)
            Task { await self?.handleLocalICECandidate(box.dict) }
        }
        await peer.setICEStateHandler { [weak self] (state: String) in
            self?.handleICEState(state)
        }
        await peer.setVideoFrameHandler { [weak self] image, size in
            self?.session.reportFrame(image, size: size)
        }
        await peer.setCodecHandler { [weak self] name in
            self?.decodeQueue.async { self?.encodedCodec = name.replacingOccurrences(of: "video/", with: "") }
        }
        await peer.setEncodedFrameHandler { [weak self] bytes, timestamp in
            self?.decodeQueue.async { self?.decodeEncodedFrame(bytes, timestamp: timestamp) }
        }
        await peer.setDataChannelStateHandler("CONTROL_DATA_CHANNEL") { [weak self] (state: String) in
            self?.controlChannelOpen = state == "open"
            if state == "open" { self?.startControlChannelHeartbeat() }
        }
        await peer.setDataChannelStateHandler("BINARY_DATA_CHANNEL") { [weak self] (state: String) in
            self?.binaryChannelOpen = state == "open"
        }
        await peer.setDataChannelStateHandler("FILE_DATA_CHANNEL") { [weak self] (state: String) in
            self?.fileChannelOpen = state == "open"
        }
        await peer.setDataChannelStateHandler("STREAMER_DATA_CHANNEL") { [weak self] (state: String) in
            self?.streamerChannelOpen = state == "open"
        }
        await peer.setDataChannelStateHandler("TEXT_DATA_CHANNEL") { [weak self] (state: String) in
            self?.textChannelOpen = state == "open"
        }
        await peer.setDataChannelHandler("CONTROL_DATA_CHANNEL") { [weak self] data in
            self?.handleControlChannel(data)
        }
        await peer.setDataChannelHandler("BINARY_DATA_CHANNEL") { [weak self] data in
            self?.handleBinaryChannel(data)
        }
        await peer.setDataChannelHandler("FILE_DATA_CHANNEL") { [weak self] data in
            self?.handleFileChannel(data)
        }
        await peer.setDataChannelHandler("STREAMER_DATA_CHANNEL") { [weak self] data in
            self?.handleStreamerChannel(data)
        }
        await peer.setDataChannelHandler("TEXT_DATA_CHANNEL") { [weak self] data in
            self?.handleTextChannel(data)
        }
    }

    // MARK: - Signaling handlers

    private func handleSignalEvent(_ event: String, args: [[String: Any]]) {
        switch event {
        case "control":
            // The host may push an offer through a control event too.
            if let first = args.first, let sdp = Self.sdpField(first) {
                Task { await self.handleRemoteOffer(sdp) }
            }
        // "soac" is intentionally NOT routed here: `onSOAC` on the
        // signaling client delivers every soac — plain `42` events and
        // hydrated binary `451-` events alike — to `handleSOAC` once.
        case "be-controlled":
            session.reportHint("Host acknowledged the control request")
        default:
            break
        }
    }

    /// `sdp` arrives either plain or as `gzip_sdp` base64 (the placeholder
    /// hydration already produced the base64 string for binary fields).
    static func sdpField(_ body: [String: Any]) -> String? {
        if let sdp = body["sdp"] as? String, sdp.count <= 1024 * 1024 { return sdp }
        if let compressed = body["gzip_sdp"] as? String,
           let data = Data(base64Encoded: compressed) {
            return String(decoding: UUGzip.decompress(data), as: UTF8.self)
        }
        return nil
    }

    private func handleSOAC(_ raw: [String: Any]) async {
        // Upstream `Peer::receive`: the payload sits under `data` when the
        // envelope is {client_id, data:{…}}, or is the event itself.
        let soac = (raw["data"] as? [String: Any]) ?? raw
        // Route filtering (upstream `matches_route`): ids must match when
        // present.
        if let client = raw["client_id"] as? String, !remoteClientID.isEmpty, client != remoteClientID { return }
        if let ice = soac["ice_id"] as? String, ice != iceID { return }
        if let app = soac["app_control_id"] as? String, app != appControlID { return }
        switch soac["type"] as? String {
        case "offer":
            guard let sdp = Self.sdpField(soac) else { return }
            await handleRemoteOffer(sdp)
        case "answer":
            guard let sdp = Self.sdpField(soac) else { return }
            await applyRemoteAnswer(sdp)
        case "candidate":
            await addLocalICECandidate(soac)
        case "restart_ice":
            try? await sendWebRTCOffer(iceRestart: true)
        default:
            break
        }
    }

    /// The viewer's SDP offer, sent over `soac` as
    /// `{client_id, data:{type:"offer", sdp, ice_id, app_control_id,
    /// ice_network_type:3}}` — the upstream `Peer::offer` shape.
    private func sendWebRTCOffer(iceRestart: Bool) async throws {
        guard let peer, !remoteClientID.isEmpty else { return }
        guard var sdp: String = try await peer.evaluate("offer(\(iceRestart ? "true" : "false"))") else {
            throw UUDriverError.webkitUnavailable
        }
        // The official Mac viewer's offer carries a bare session-level
        // a=x-uuremote-quic and a 256 KB max-message-size on the SCTP m-line
        // (sent copy only — setLocalDescription already consumed the original).
        if !sdp.contains("a=x-uuremote-quic"), let group = sdp.range(of: "a=group:BUNDLE") {
            sdp.insert(contentsOf: "a=x-uuremote-quic\r\n", at: group.lowerBound)
        }
        if !sdp.contains("a=max-message-size:") {
            sdp = Self.withMaxMessageSize(sdp)
        }
        try await signalClient.sendSOAC([
            "client_id": remoteClientID,
            "data": [
                "type": "offer",
                "sdp": sdp,
                "ice_id": iceID,
                "app_control_id": appControlID,
                "ice_network_type": 3,
            ],
        ])
        session.reportHint("SDP offer sent")
    }

    /// Inserts `a=max-message-size:262144` after each `a=sctp-port:` line —
    /// the host otherwise assumes 64 KB and drops larger replies (upstream
    /// `with_max_message_size`).
    static func withMaxMessageSize(_ sdp: String) -> String {
        let eol = sdp.contains("\r\n") ? "\r\n" : "\n"
        var out = ""
        for rawLine in sdp.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            out += line + eol
            if line.hasPrefix("a=sctp-port:") {
                out += "a=max-message-size:262144" + eol
            }
        }
        return out
    }

    /// A host-pushed offer (some flows): answer it over the same SOAC
    /// envelope shape.
    private func handleRemoteOffer(_ sdp: String) async {
        guard let peer else { return }
        do {
            guard let answerSDP: String = try await peer.evaluate(
                "offerDesc(\(Self.javascriptString(sdp)))"
            ) else { return }
            try await signalClient.sendSOAC([
                "client_id": remoteClientID,
                "data": [
                    "type": "answer",
                    "sdp": answerSDP,
                    "ice_id": iceID,
                    "app_control_id": appControlID,
                ],
            ])
            session.reportHint("SDP answer sent")
        } catch {
            reportTerminal(.failed("UU Remote SDP answer failed: \(error.localizedDescription)"))
        }
    }

    private func handleLocalICECandidate(_ candidate: [String: Any]) async {
        if candidate["done"] as? Bool == true { return }
        await sendLocalICECandidate(candidate)
    }

    /// Outbound `{client_id, data:{type:"candidate", candidate:{…},
    /// ice_id, app_control_id}}` — `candidate` is the RTCIceCandidateInit
    /// object, matching upstream's `{"candidate": value}` shape.
    private func sendLocalICECandidate(_ candidate: [String: Any]) async {
        guard !remoteClientID.isEmpty else { return }
        let init_: [String: Any] = [
            "candidate": candidate["candidate"] ?? "",
            "sdpMid": candidate["sdpMid"] ?? NSNull(),
            "sdpMLineIndex": candidate["sdpMLineIndex"] ?? NSNull(),
        ]
        try? await signalClient.sendSOAC([
            "client_id": remoteClientID,
            "data": [
                "type": "candidate",
                "candidate": init_,
                "ice_id": iceID,
                "app_control_id": appControlID,
            ],
        ])
    }

    private func applyRemoteAnswer(_ sdp: String) async {
        guard let peer else { return }
        if answered { return }
        answered = true
        _ = try? await peer.evaluate("answer(\(Self.javascriptString(sdp)))") as String?
        // Learn the negotiated video payload types for the RTP path.
        let h265 = Self.payloadTypes(forCodec: "H265", in: sdp)
        if !h265.isEmpty { videoAssembler.h265PayloadTypes = h265 }
        for candidate in earlyCandidates {
            _ = try? await peer.evaluate("addIce(\(Self.javascriptObject(candidate)))") as String?
        }
        earlyCandidates.removeAll()
    }

    /// `a=rtpmap:<pt> H265/90000` payload types in the negotiated SDP.
    static func payloadTypes(forCodec codec: String, in sdp: String) -> Set<UInt8> {
        var types = Set<UInt8>()
        for line in sdp.components(separatedBy: .newlines) {
            guard line.hasPrefix("a=rtpmap:"), line.contains(codec) else { continue }
            let pt = line.dropFirst("a=rtpmap:".count).split(separator: " ").first.flatMap { UInt8($0) }
            if let pt { types.insert(pt) }
        }
        return types
    }

    /// Inbound candidates: `candidate` may be a bare string or an
    /// RTCIceCandidateInit object; queue until the answer lands.
    private func addLocalICECandidate(_ soac: [String: Any]) async {
        guard let peer else { return }
        var candidate: [String: Any] = [:]
        if let string = soac["candidate"] as? String {
            candidate = [
                "candidate": string,
                "sdpMid": soac["sdp_mid"] ?? NSNull(),
                "sdpMLineIndex": soac["sdp_m_line_index"] ?? NSNull(),
            ]
        } else if let object = soac["candidate"] as? [String: Any] {
            candidate = object
        } else {
            return
        }
        if answered {
            _ = try? await peer.evaluate("addIce(\(Self.javascriptObject(candidate)))") as String?
        } else {
            if earlyCandidates.count >= 256 { return }
            earlyCandidates.append(candidate)
        }
    }

    private func restartICE() async {
        // Unlatch `answered` so the renegotiated answer is applied —
        // `applyRemoteAnswer` drops answers once the first one landed.
        answered = false
        try? await sendWebRTCOffer(iceRestart: true)
    }

    private func handleICEState(_ state: String) {
        session.reportHint("ICE \(state)")
        if state == "connected" {
            session.reportPhase(.connected)
        } else if state == "failed" || state == "disconnected" {
            reportTerminal(.failed("UU Remote ICE \(state)"))
        }
    }

    // MARK: - Data channel senders

    private func sendControlChannel(_ data: Data) {
        guard let peer, controlChannelOpen else { return }
        Task { _ = try? await peer.evaluate("dcSend('CONTROL_DATA_CHANNEL', \(Self.javascriptArray(data)))") as String? }
    }

    private func sendBinaryChannel(_ data: Data) {
        guard let peer, binaryChannelOpen else { return }
        Task { _ = try? await peer.evaluate("dcSend('BINARY_DATA_CHANNEL', \(Self.javascriptArray(data)))") as String? }
    }

    private func sendFileChannel(_ data: Data) {
        guard let peer, fileChannelOpen else { return }
        Task { _ = try? await peer.evaluate("dcSend('FILE_DATA_CHANNEL', \(Self.javascriptArray(data)))") as String? }
    }

    private func sendStreamerChannel(_ data: Data) {
        guard let peer, streamerChannelOpen else { return }
        Task { _ = try? await peer.evaluate("dcSend('STREAMER_DATA_CHANNEL', \(Self.javascriptArray(data)))") as String? }
    }

    private func sendTextChannel(_ data: Data) {
        guard let peer, textChannelOpen else { return }
        Task { _ = try? await peer.evaluate("dcSend('TEXT_DATA_CHANNEL', \(Self.javascriptArray(data)))") as String? }
    }

    // MARK: - Inbound data channels

    private func handleControlChannel(_ data: Data) {
        // Desktop input JSON also arrives as raw text on this channel — the
        // protobuf envelope decode just returns nil for it.
        guard let inbound = UUControlProtocol.decodeInbound(data) else { return }
        switch inbound.field.number {
        case UUControlField.simpleAction:
            if case let .bytes(body) = inbound.field.value,
               let action = UUControlProtocol.decodeSimpleAction(body) {
                handleSimpleAction(action)
            }
        case UUControlField.screenSources:
            if case let .bytes(body) = inbound.field.value {
                let sources = UUControlProtocol.decodeScreenSources(body)
                session.reportDisplays(sources, selected: session.machine.uuDisplayID)
            }
        case UUControlField.captureChange:
            if case let .bytes(body) = inbound.field.value,
               let change = UUControlProtocol.decodeCaptureChange(body) {
                session.reportHint("Capture changed to screen \(change.captureID)")
            }
        case UUControlField.systemStateChange:
            if case let .bytes(body) = inbound.field.value,
               let change = UUControlProtocol.decodeSystemStateChange(body) {
                if let locked = change.isLocked {
                    session.reportPhase(locked ? .authenticating : .connected)
                }
                if let cursor = change.cursor { session.reportCursor(cursor) }
            }
        case UUControlField.portMappingFrame:
            if let frame = UUPortMappingEnvelope.unwrap(data) {
                portMapping.handle(frame: frame)
            }
        default:
            break
        }
    }

    private func handleSimpleAction(_ action: (action: UInt64, argsJSON: String?, featureFlags: UUFeatureFlags)) {
        switch action.action {
        case UUSimpleActionType.echoRequest:
            let seq = (action.argsJSON.flatMap { args -> UInt64? in
                guard let data = args.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let seq = json["seq"] as? NSNumber else { return nil }
                return seq.uint64Value
            }) ?? 0
            sendControlChannel(UUControlProtocol.echoResponseEnvelope(
                sequence: nextOutboundSequence(),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                requestSequence: seq,
                clipboardEnabled: true
            ))
        case UUSimpleActionType.echoResponse:
            session.reportHint("UU Remote echo \(action.argsJSON ?? "")")
        default:
            break
        }
    }

    private func handleBinaryChannel(_ data: Data) {
        guard UUTerminalFrame.isFrame(data), let frame = UUTerminalFrame.decode(data) else { return }
        // A terminal's frames go to it; with one open, frames whose id the
        // host renumbered go to that one too.
        if closedTerminalIDs.contains(frame.sessionID) { return }
        if let sink = terminalSinks[frame.sessionID] ?? (terminalSinks.count == 1 ? terminalSinks.values.first : nil) {
            sink(frame)
            return
        }
        switch frame.kind {
        case .stdout:
            session.reportHint(String(decoding: frame.payload, as: UTF8.self))
        case .openResp:
            if let resp = UUTerminalJSON.decodeOpenResponse(frame.payload) {
                session.reportHint("UU Remote terminal open \(resp.code) \(resp.message)")
            }
        case .exit:
            if let code = UUTerminalJSON.decodeExit(frame.payload) {
                session.reportHint("UU Remote terminal exited \(code)")
            }
        default:
            break
        }
    }

    private func handleFileChannel(_ data: Data) {
        guard let frame = UUPortMappingEnvelope.unwrap(data) else { return }
        portMapping.handle(frame: frame)
    }

    private func handleStreamerChannel(_ data: Data) {
        guard let packet = UURTPVideoAssembler.parsePacket(data),
              let accessUnit = videoAssembler.insert(packet),
              let image = videoDecoder.decode(accessUnit: accessUnit) else { return }
        session.reportFrame(image, size: videoDecoder.outputSize)
    }

    /// One encoded frame from the WebRTC receiver, Annex-B. On decodeQueue.
    private func decodeEncodedFrame(_ bytes: Data, timestamp: UInt32) {
        let nalUnits = UUVideoAccessUnit.nalUnits(annexB: bytes)
        // The stream says its codec in a key frame's parameter sets, before
        // the receiver's stats do.
        if let codec = UUVideoAccessUnit.codec(ofParameterSetsIn: nalUnits) { encodedCodec = codec }
        let unit = UUVideoAccessUnit(nalUnits: nalUnits, sequence: 0, timestamp: timestamp, codecName: encodedCodec)
        let image = encodedDecoder.decode(accessUnit: unit)
        encodedCount += 1
        // Undecodable frames in a row: the decoder starts over at the next
        // key frame, which the host is asked for.
        failedDecodes = image == nil ? failedDecodes + 1 : 0
        if failedDecodes == 30 {
            encodedDecoder.reset()
            requestKeyframeOrRefresh()
        }
        if encodedCount <= 3 || (image == nil && encodedCount.isMultiple(of: 200)) {
            let types = unit.nalUnits.prefix(8).map { nal in nal.isEmpty ? -1 : Int((nal[nal.startIndex] >> 1) & 0x3F) }
            Self.log.info("encoded frame \(self.encodedCount): \(bytes.count) bytes, \(self.encodedCodec, privacy: .public) NAL types \(types, privacy: .public), decoded \(image != nil)")
        }
        guard let image else { return }
        session.reportFrame(image, size: encodedDecoder.outputSize)
    }
    private var encodedCount = 0
    private var failedDecodes = 0
    private static let log = Logger(subsystem: "me.mizorewww.rayon", category: "uu-driver")

    private func handleTextChannel(_ data: Data) {
        // Clipboard V3 inbound: case-10 text-change request -> surface the
        // text and acknowledge with a case-6 response (CB_SUCCEEDED).
        if let change = UUControlProtocol.decodeClipboardTextChange(data) {
            session.reportRemoteClipboard(change.text)
            sendTextChannel(UUControlProtocol.clipboardTextChangeResponse(
                requestID: nextOutboundSequence(),
                header: change.header
            ))
            return
        }
        session.reportHint("UU Remote text: \(String(decoding: data, as: UTF8.self))")
    }

    // MARK: - Terminal & port mapping (extra UU Remote services)

    /// Opens a UU Remote terminal stream on BINARY_DATA_CHANNEL.
    public func openTerminal(cols: Int, rows: Int, shell: String = "/bin/zsh") {
        let frame = UUTerminalFrame(kind: .open, sessionID: 1, payload: UUTerminalJSON.open(cols: cols, rows: rows, shell: shell))
        sendBinaryChannel(frame.encode())
    }

    /// Opens a terminal of its own and returns its TERM session id; its
    /// frames (output, exit, errors) go to `onFrame`. Main thread.
    public func openTerminal(cols: Int, rows: Int, onFrame: @escaping (UUTerminalFrame) -> Void) -> UInt32 {
        let id = nextTerminalID
        nextTerminalID += 1
        terminalSinks[id] = onFrame
        // The host's own default shell on Windows; the login shell on a Mac.
        let shell = targetIsWindows ? "powershell.exe" : "/bin/zsh"
        sendBinaryChannel(UUTerminalFrame(kind: .open, sessionID: id, payload: UUTerminalJSON.open(cols: cols, rows: rows, shell: shell)).encode())
        return id
    }

    /// Ends a terminal and stops delivering its frames. Main thread.
    public func closeTerminal(_ id: UInt32) {
        guard terminalSinks.removeValue(forKey: id) != nil else { return }
        closedTerminalIDs.insert(id)
        sendBinaryChannel(UUTerminalFrame(kind: .close, sessionID: id).encode())
    }

    public var openTerminalCount: Int { terminalSinks.count }

    /// Sends stdin bytes to the host's terminal session.
    public func sendTerminalStdin(_ data: Data, sessionID: UInt32 = 1) {
        sendBinaryChannel(UUTerminalFrame(kind: .stdin, sessionID: sessionID, payload: data).encode())
    }

    /// Resizes the host's terminal session.
    public func sendTerminalResize(cols: Int, rows: Int, sessionID: UInt32 = 1) {
        sendBinaryChannel(UUTerminalFrame(kind: .resize, sessionID: sessionID, payload: UUTerminalJSON.resize(cols: cols, rows: rows)).encode())
    }

    /// Opens a port-mapped socket for SSH/SFTP through the UU host.
    public func openPortMapping(targetHost: String, targetPort: UInt16) throws -> Int32 {
        let result = portMapping.openStream(targetHost: targetHost, targetPort: targetPort, timeout: 20)
        switch result {
        case let .success(fd): return fd
        case let .failure(failure): throw failure
        }
    }

    /// Sends a raw JSON RPC on CONTROL_DATA_CHANNEL (same transport as the
    /// desktop input messages).
    public func sendRPC(method: String, params: [String: Any] = [:]) {
        var dict = params
        dict["action"] = method
        guard let body = try? JSONSerialization.data(withJSONObject: dict) else { return }
        sendControlChannel(body)
    }

    // MARK: - Terminal phase helpers

    /// Reports a terminal phase once, so `stop()` does not overwrite a
    /// `.failed` with a plain `.closed`.
    private func reportTerminal(_ phase: RemoteDesktopPhase, hint: String? = nil) {
        reportedTerminalPhase = true
        session.reportPhase(phase, hint: hint)
    }

    // MARK: - Heartbeat

    private func startControlChannelHeartbeat() {
        connectTimeoutTask?.cancel()
        session.reportPhase(.connected)
        session.reportHint("Control channel open")

        // A `uuDisplayID` the user pinned applies as soon as control is up.
        if !requestedDisplayApplied, session.machine.uuDisplayID != 0 {
            requestedDisplayApplied = true
            selectDisplay(session.machine.uuDisplayID)
        }

        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled, let self {
                // Protobuf echo (SimpleAction echo_request) keeps the
                // control association alive like the upstream viewer.
                self.sendControlChannel(UUControlProtocol.echoRequestEnvelope(
                    sequence: self.nextOutboundSequence(),
                    timestamp: UInt64(Date().timeIntervalSince1970 * 1000)
                ))
                // The host's input watchdog also wants the JSON keyboard
                // heartbeat roughly once a second.
                tick += 1
                if tick % 10 == 0 {
                    self.sendControlChannel(UUControlProtocol.keyboardHeartbeat())
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        videoRequestTask?.cancel()
        guard purpose == .desktop else { return }
        videoRequestTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !self.closed else { return }
            // One sendVideoTrack RPC once the channel is up (like the
            // official iPhone viewer); 4:4:4 true colour rides a separate
            // CaptureSettingRequest when the quality tier asks for it.
            self.sendControlChannel(UUControlProtocol.sendVideoTrackRequest(requestID: self.nextOutboundSequence()))
            if self.session.machine.uuQuality >= 4 {
                self.sendControlChannel(UUControlProtocol.captureSettingRequest(
                    requestID: self.nextOutboundSequence(),
                    chromaFormat: Int32(UUChromaFormat.c444)
                ))
            }
        }
    }

    // MARK: - Helpers

    private func nextOutboundSequence() -> UInt64 {
        outboundLock.withLock {
            outboundSequence += 1
            return outboundSequence
        }
    }

    private static func javascriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func javascriptObject(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private static func javascriptArray(_ data: Data) -> String {
        "[\(data.map(String.init).joined(separator: ","))]"
    }
}

/// The WebKit RTCPeerConnection wrapper that runs inside a hidden WKWebView.
@MainActor
private final class UURTCPeerConnection: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// The page runs here, in process, where WebKit has WebRTC (iOS, macOS)…
    private let webView: WKWebView?
    #if targetEnvironment(macCatalyst)
        /// …and in the helper on Mac Catalyst, where it does not.
        private var helper: UURTCHelperProcess?
    #endif
    private var ready = false
    /// The page could not load, or its helper ended.
    private var failedReason: String?
    private var failureHandler: ((String) -> Void)?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var candidateHandler: (([String: Any]) -> Void)?
    private var dataChannelHandlers: [String: (Data) -> Void] = [:]
    private var dataChannelStateHandlers: [String: (String) -> Void] = [:]
    private var trackHandler: ((String, Data) -> Void)?
    private var videoFrameHandler: ((CGImage, CGSize) -> Void)?
    private var encodedFrameHandler: ((Data, UInt32) -> Void)?
    private var codecHandler: ((String) -> Void)?
    private var iceStateHandler: ((String) -> Void)?

    override init() {
        #if targetEnvironment(macCatalyst)
            if let executable = UURTCHelperProcess.executableURL,
               let helper = try? UURTCHelperProcess(executable: executable)
            {
                webView = nil
                self.helper = helper
                super.init()
                helper.onEvent = { [weak self] body in self?.handlePageMessage(body) }
                helper.onReady = { [weak self] loaded, reason in self?.pageLoaded(loaded, reason: reason) }
                loadBridge()
                return
            }
        #endif
        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        // The remote screen is a muted video nobody taps on: it must play
        // without a user gesture, and inline.
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
            config.allowsInlineMediaPlayback = true
        #endif
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16), configuration: config)
        self.webView = webView
        super.init()
        config.userContentController.add(self, name: "rtc")
        webView.navigationDelegate = self
        loadBridge()
    }

    private func loadBridge() {
        let html = """
        <!doctype html><html><body><script>
        let pc = null; let channels = {}; let channelsMade = false;
        let videoEl = null; let videoCanvas = null; let frameTimer = null;
        function post(name, data) { window.webkit.messageHandlers.rtc.postMessage({name: name, data: data}); }
        // Encoded frames straight off the receiver, decoded natively: the page
        // is in no window, so WebKit never plays a <video> here.
        const transformSource = `onrtctransform = (event) => {
            const t = event.transformer;
            t.readable.pipeThrough(new TransformStream({ transform(frame, out) {
                if (frame.data && frame.data.byteLength) {
                    const copy = frame.data.slice(0);
                    self.postMessage({key: frame.type === 'key', ts: frame.timestamp, data: copy}, [copy]);
                }
                out.enqueue(frame);
            } })).pipeTo(t.writable);
        };`;
        let transformWorker = null;
        function base64(bytes) {
            let text = '';
            for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
            return btoa(text);
        }
        function transformReceiver(receiver) {
            if (!window.RTCRtpScriptTransform) return false;
            if (!transformWorker) {
                transformWorker = new Worker(URL.createObjectURL(new Blob([transformSource], {type: 'text/javascript'})));
                transformWorker.onmessage = m => post('encoded', {data: base64(new Uint8Array(m.data.data)), ts: m.data.ts, key: m.data.key});
            }
            receiver.transform = new RTCRtpScriptTransform(transformWorker, {});
            return true;
        }
        function makePeer(iceServers, forceRelay) {
            pc = new RTCPeerConnection({ iceServers: iceServers || [], iceTransportPolicy: forceRelay ? 'relay' : 'all' });
            pc.onicecandidate = e => post('icecandidate', e.candidate ? {sdpMid: e.candidate.sdpMid, sdpMLineIndex: e.candidate.sdpMLineIndex, candidate: e.candidate.candidate} : {done: true});
            pc.oniceconnectionstatechange = () => post('icestate', {state: pc.iceConnectionState});
            pc.ondatachannel = e => {
                const ch = e.channel;
                ch.binaryType = 'arraybuffer';
                ch.onopen = () => post('dc_open', {label: ch.label});
                ch.onclose = () => post('dc_close', {label: ch.label});
                ch.onmessage = m => post('dc_message', {label: ch.label, data: Array.from(new Uint8Array(m.data))});
                channels[ch.label] = ch;
            };
            pc.ontrack = e => {
                if (e.track.kind === 'video') {
                    const transformed = transformReceiver(e.receiver);
                    if (!transformed) attachVideo(e.streams && e.streams[0] ? e.streams[0] : new MediaStream([e.track]));
                    post('track', {kind: 'video', id: e.track.id, transformed: transformed});
                }
            };
            setInterval(async () => {
                if (!pc) return;
                const report = await pc.getStats();
                const codecs = {}; const inbound = [];
                report.forEach(r => { if (r.type === 'codec') codecs[r.id] = r.mimeType; });
                report.forEach(r => { if (r.type === 'inbound-rtp' && r.kind === 'video' && r.bytesReceived > 0) inbound.push({codec: codecs[r.codecId] || '', bytes: r.bytesReceived, decoded: r.framesDecoded || 0, w: r.frameWidth || 0, h: r.frameHeight || 0}); });
                post('stats', {video: inbound, ready: videoEls.map(v => v.readyState)});
                if (inbound.length) post('codec', {name: inbound[0].codec});
            }, 3000);
            return 'ok';
        }
        // The offer asks for five video tracks and the host fills one: each
        // gets an element, and frames come from whichever is playing.
        let videoEls = [];
        function attachVideo(stream) {
            const el = document.createElement('video');
            el.muted = true; el.autoplay = true; el.playsInline = true;
            el.width = 16; el.height = 16;
            document.body.appendChild(el);
            el.srcObject = stream;
            el.play().catch(() => {});
            videoEls.push(el);
            if (!frameTimer) {
                videoCanvas = document.createElement('canvas');
                const ctx = videoCanvas.getContext('2d');
                frameTimer = setInterval(() => {
                    videoEl = videoEls.find(v => v.readyState >= 2 && v.videoWidth > 0) || null;
                    if (!videoEl) { videoEls.forEach(v => { if (v.paused) v.play().catch(() => {}); }); return; }
                    if (videoCanvas.width !== videoEl.videoWidth || videoCanvas.height !== videoEl.videoHeight) {
                        videoCanvas.width = videoEl.videoWidth;
                        videoCanvas.height = videoEl.videoHeight;
                    }
                    ctx.drawImage(videoEl, 0, 0);
                    try {
                        const url = videoCanvas.toDataURL('image/jpeg', 0.7);
                        post('video_frame', {jpeg: url.substring(url.indexOf(',') + 1), width: videoCanvas.width, height: videoCanvas.height});
                    } catch (e) {}
                }, 66);
            }
        }
        function ensureChannels() {
            if (channelsMade) return;
            channelsMade = true;
            const labels = ['STREAMER_DATA_CHANNEL','FILE_DATA_CHANNEL','TEXT_DATA_CHANNEL','BINARY_DATA_CHANNEL','CONTROL_DATA_CHANNEL'];
            for (const label of labels) {
                const ch = pc.createDataChannel(label, {ordered: true});
                ch.binaryType = 'arraybuffer';
                ch.onopen = () => post('dc_open', {label: ch.label});
                ch.onclose = () => post('dc_close', {label: ch.label});
                ch.onmessage = m => post('dc_message', {label: ch.label, data: typeof m.data === 'string' ? Array.from(new TextEncoder().encode(m.data)) : Array.from(new Uint8Array(m.data))});
                channels[label] = ch;
            }
            for (let i = 0; i < 5; i++) pc.addTransceiver('video', {direction: 'recvonly'});
            pc.addTransceiver('audio', {direction: 'recvonly'});
        }
        async function offer(iceRestart) {
            ensureChannels();
            const o = await pc.createOffer(iceRestart ? {iceRestart: true} : {});
            await pc.setLocalDescription(o);
            return o.sdp;
        }
        async function answer(sdp) { await pc.setRemoteDescription({type: 'answer', sdp: sdp}); return 'ok'; }
        async function offerDesc(sdp) { await pc.setRemoteDescription({type: 'offer', sdp: sdp}); const a = await pc.createAnswer(); await pc.setLocalDescription(a); return a.sdp; }
        async function addIce(c) { await pc.addIceCandidate(c); return 'ok'; }
        function dcSend(label, data) { channels[label] && channels[label].send(new Uint8Array(data)); }
        function dcClose(label) { channels[label] && channels[label].close(); }
        function closeAll() { if (frameTimer) { clearInterval(frameTimer); frameTimer = null; } for (const k in channels) { try { channels[k].close(); } catch (e) {} } if (pc) { try { pc.close(); } catch (e) {} } return 'ok'; }
        </script></body></html>
        """
        // An origin of its own, so the page may start a worker from a blob.
        let base = "https://rtc.catussh.invalid/"
        #if targetEnvironment(macCatalyst)
            if let helper {
                helper.load(html: html, baseURL: base)
                return
            }
        #endif
        webView?.loadHTMLString(html, baseURL: URL(string: base))
    }

    private static let log = Logger(subsystem: "me.mizorewww.rayon", category: "uu-rtc")
    /// Messages seen per data channel, to log the first few of each.
    private var messageCounts: [String: Int] = [:]

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "rtc" else { return }
        handlePageMessage(message.body)
    }

    /// A message the page posted, from either host.
    private func handlePageMessage(_ message: Any) {
        guard let body = message as? [String: Any],
              let name = body["name"] as? String,
              let data = body["data"] as? [String: Any]
        else { return }
        switch name {
        case "dc_message":
            let label = data["label"] as? String ?? ""
            let count = messageCounts[label, default: 0] + 1
            messageCounts[label] = count
            if count <= 3 || count.isMultiple(of: 500) {
                Self.log.info("\(label, privacy: .public) message \(count), \((data["data"] as? [Any])?.count ?? 0) bytes")
            }
        case "video_frame", "encoded":
            let count = messageCounts[name, default: 0] + 1
            messageCounts[name] = count
            if count <= 2 || count.isMultiple(of: 300) { Self.log.info("\(name, privacy: .public) \(count)") }
        case "icecandidate", "codec":
            break
        default:
            Self.log.info("\(name, privacy: .public) \(String(describing: data), privacy: .public)")
        }
        switch name {
        case "icecandidate":
            candidateHandler?(data)
        case "icestate":
            iceStateHandler?(data["state"] as? String ?? "")
        case "dc_open":
            dataChannelStateHandlers[data["label"] as? String ?? ""]?("open")
        case "dc_close":
            dataChannelStateHandlers[data["label"] as? String ?? ""]?("close")
        case "dc_message":
            if let label = data["label"] as? String, let bytes = data["data"] as? [Int] {
                let raw = Data(bytes.map { UInt8($0 & 0xFF) })
                dataChannelHandlers[label]?(raw)
            }
        case "track":
            trackHandler?(data["kind"] as? String ?? "", Data())
        case "encoded":
            if let text = data["data"] as? String, let bytes = Data(base64Encoded: text) {
                encodedFrameHandler?(bytes, (data["ts"] as? NSNumber)?.uint32Value ?? 0)
            }
        case "codec":
            codecHandler?(data["name"] as? String ?? "")
        case "video_frame":
            if let jpeg = data["jpeg"] as? String,
               let jpegData = Data(base64Encoded: jpeg, options: .ignoreUnknownCharacters),
               let image = Self.cgImage(fromJPEG: jpegData) {
                let width = (data["width"] as? NSNumber)?.doubleValue ?? Double(image.width)
                let height = (data["height"] as? NSNumber)?.doubleValue ?? Double(image.height)
                videoFrameHandler?(image, CGSize(width: width, height: height))
            }
        default:
            break
        }
    }

    /// JPEG → CGImage via ImageIO — no UIKit/AppKit dependency.
    private static func cgImage(fromJPEG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoaded(false)
    }

    private func pageLoaded(_ loaded: Bool, reason: String? = nil) {
        if loaded {
            ready = true
            readyContinuation?.resume()
        } else {
            let why = reason ?? "The WebRTC page could not load."
            failedReason = why
            readyContinuation?.resume(throwing: RemoteDesktopFailure(why))
            // Already running: the session goes with its page.
            if ready { failureHandler?(why) }
        }
        readyContinuation = nil
    }

    func setFailureHandler(_ handler: @escaping (String) -> Void) {
        failureHandler = handler
        if ready, let failedReason { handler(failedReason) }
    }

    func waitReady() async throws {
        if ready { return }
        if let failedReason { throw RemoteDesktopFailure(failedReason) }
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
        }
    }

    /// Runs a call into the page and waits for it: most of the page's
    /// functions are async, and evaluateJavaScript cannot return a Promise
    /// ("a result of an unsupported type"), nor `undefined`.
    func evaluate<T>(_ script: String) async throws -> T? {
        do {
            #if targetEnvironment(macCatalyst)
                if let helper { return try await helper.evaluate(script) as? T }
            #endif
            let result = try await webView?.callAsyncJavaScript("return await (\(script));", contentWorld: .page)
            return result as? T
        } catch {
            // WebKit's own message is only "A JavaScript exception occurred".
            let info = (error as NSError).userInfo
            let message = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            let call = script.prefix { $0 != "(" }
            Self.log.error("\(call, privacy: .public) threw: \(message, privacy: .public)")
            throw RemoteDesktopFailure("WebRTC \(call): \(message)")
        }
    }

    func setCandidateHandler(_ handler: @escaping ([String: Any]) -> Void) { candidateHandler = handler }
    func setDataChannelHandler(_ label: String, handler: @escaping (Data) -> Void) { dataChannelHandlers[label] = handler }
    func setDataChannelStateHandler(_ label: String, handler: @escaping (String) -> Void) { dataChannelStateHandlers[label] = handler }
    func setTrackHandler(_ handler: @escaping (String, Data) -> Void) { trackHandler = handler }
    func setVideoFrameHandler(_ handler: @escaping (CGImage, CGSize) -> Void) { videoFrameHandler = handler }
    func setEncodedFrameHandler(_ handler: @escaping (Data, UInt32) -> Void) { encodedFrameHandler = handler }
    func setCodecHandler(_ handler: @escaping (String) -> Void) { codecHandler = handler }
    func setICEStateHandler(_ handler: @escaping (String) -> Void) { iceStateHandler = handler }
}
