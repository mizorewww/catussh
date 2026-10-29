//
//  UURemoteSignalingClient.swift
//  CatusshModule
//
//  Engine.IO v4 / Socket.IO v4 WebSocket client for UU Remote room signaling:
//  handshake, heartbeats, the `control` event with binary ConnectOptions, and
//  soac offer/answer/candidate routing. Mirrors
//  /tmp/uu-refs/openuuyc/src/transport/signal/wire.rs and
//  /tmp/uu-refs/uurc-web/backend/src/services/socketIoSignalGatewayConnector.ts.
//

import Compression
import Foundation
import zlib

public enum UUSignalError: Error, Sendable {
    case invalidURL(String)
    case notConnected
    case transport(String)
    case malformedFrame(String)
    case controlRejected(Int, String)
    case timeout(String)
}

public enum UUSignalPacket {
    case open([String: Any])
    case close
    case ping(String)
    case pong(String)
    case message(UUSocketPacket)
    case upgrade
    case noop
}

public enum UUSocketPacket {
    case connect(namespace: String, data: [String: Any]?)
    case disconnect(namespace: String)
    case event(namespace: String, id: UInt64?, event: String, args: [[String: Any]], binary: [Data])
    case binaryEvent(namespace: String, id: UInt64?, event: String, args: [[String: Any]], attachmentCount: Int)
    /// An ack reply: the *full* args array (the control ack is
    /// `["success", {…}]` — a string head, not a dictionary).
    case ack(namespace: String, id: UInt64, args: [Any])
    case connectError(namespace: String, data: [String: Any])
}

/// A minimal Engine.IO v4 / Socket.IO v4 codec.
public enum UUEngineIO {
    public static func decode(_ frame: String) throws -> UUSignalPacket {
        guard !frame.isEmpty else { throw UUSignalError.malformedFrame("empty Engine.IO frame") }
        let kind = frame.prefix(1)
        let payload = String(frame.dropFirst(1))
        switch kind {
        case "0":
            guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                throw UUSignalError.malformedFrame("Engine.IO open is not JSON")
            }
            return .open(json)
        case "1" where payload.isEmpty: return .close
        case "2": return .ping(payload)
        case "3": return .pong(payload)
        case "4": return .message(try decodeSocket(payload))
        case "5" where payload.isEmpty: return .upgrade
        case "6" where payload.isEmpty: return .noop
        default: throw UUSignalError.malformedFrame("unsupported Engine.IO packet kind \(kind)")
        }
    }

    public static func encodePong(_ payload: String) -> String { "3\(payload)" }

    public static func encodeEvent(_ event: String, args: [[String: Any]], id: UInt64? = nil) throws -> String {
        guard !event.isEmpty else { throw UUSignalError.malformedFrame("empty event name") }
        let array: [Any] = [event] + args
        guard let json = try? JSONSerialization.data(withJSONObject: array) else {
            throw UUSignalError.malformedFrame("event args are not JSON-serializable")
        }
        let idStr = id.map(String.init) ?? ""
        return "42\(idStr)\(String(decoding: json, as: UTF8.self))"
    }

    public static func encodeBinaryEvent(_ event: String, args: [[String: Any]], id: UInt64? = nil, attachmentCount: Int) throws -> String {
        guard attachmentCount > 0 else { throw UUSignalError.malformedFrame("binary event needs attachments") }
        guard !event.isEmpty else { throw UUSignalError.malformedFrame("empty event name") }
        let array: [Any] = [event] + args
        guard let json = try? JSONSerialization.data(withJSONObject: array) else {
            throw UUSignalError.malformedFrame("event args are not JSON-serializable")
        }
        let idStr = id.map(String.init) ?? ""
        return "45\(attachmentCount)-\(idStr)\(String(decoding: json, as: UTF8.self))"
    }

    public static func decodeSocket(_ input: String) throws -> UUSocketPacket {
        guard !input.isEmpty else { throw UUSignalError.malformedFrame("empty Socket.IO packet") }
        let kind = input.prefix(1)
        var rest = String(input.dropFirst(1))
        var namespace = "/"
        if rest.hasPrefix("/") {
            guard let comma = rest.firstIndex(of: ",") else {
                throw UUSignalError.malformedFrame("Socket.IO namespace missing comma")
            }
            namespace = String(rest[..<comma])
            rest = String(rest[rest.index(after: comma)...])
        }
        switch kind {
        case "0":
            let data = try? JSONSerialization.jsonObject(with: Data(rest.utf8)) as? [String: Any]
            return .connect(namespace: namespace, data: data)
        case "1" where rest.isEmpty:
            return .disconnect(namespace: namespace)
        case "2":
            let (id, json) = splitAckID(rest)
            let (event, args) = try parseEventArray(json)
            return .event(namespace: namespace, id: id, event: event, args: args, binary: [])
        case "3":
            let (id, json) = splitAckID(rest)
            guard let id else { throw UUSignalError.malformedFrame("Socket.IO ACK has no id") }
            guard let array = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
                throw UUSignalError.malformedFrame("Socket.IO ACK args are not an array")
            }
            return .ack(namespace: namespace, id: id, args: array)
        case "4":
            guard let data = try? JSONSerialization.jsonObject(with: Data(rest.utf8)) as? [String: Any] else {
                throw UUSignalError.malformedFrame("Socket.IO connect error is not JSON")
            }
            return .connectError(namespace: namespace, data: data)
        case "5", "6":
            // Two wire forms exist:
            //  - `4[56]<n>-[<nsp>,]<id>[…]` — a binary event announcing
            //    <n> Engine.IO attachment frames that follow separately.
            //  - `4[56]<id>[…]` — the ack reply to a binary event we sent
            //    (the signal server answers `451-<ackId>` emits with
            //    `45<ackId>["success",{…}]`, per upstream wire.rs).
            if let dash = rest.firstIndex(of: "-"),
               dash > rest.startIndex,
               rest[..<dash].allSatisfy(\.isNumber),
               let attachments = Int(rest[..<dash]) {
                guard attachments > 0 else { throw UUSignalError.malformedFrame("Socket.IO binary event has no attachments") }
                rest = String(rest[rest.index(after: dash)...])
                if rest.hasPrefix("/") {
                    guard let comma = rest.firstIndex(of: ",") else {
                        throw UUSignalError.malformedFrame("Socket.IO namespace missing comma")
                    }
                    namespace = String(rest[..<comma])
                    rest = String(rest[rest.index(after: comma)...])
                }
                let (id, json) = splitAckID(rest)
                let (event, args) = try parseEventArray(json)
                return .binaryEvent(namespace: namespace, id: id, event: event, args: args, attachmentCount: attachments)
            }
            let (id, json) = splitAckID(rest)
            guard let id else { throw UUSignalError.malformedFrame("Socket.IO binary ack has no id") }
            guard let array = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] else {
                throw UUSignalError.malformedFrame("Socket.IO binary ack args are not an array")
            }
            return .ack(namespace: namespace, id: id, args: array)
        default:
            throw UUSignalError.malformedFrame("unsupported Socket.IO packet kind \(kind)")
        }
    }

    private static func splitAckID(_ input: String) -> (UInt64?, String) {
        var index = input.startIndex
        var digits = ""
        while index < input.endIndex, input[index].isNumber {
            digits.append(input[index])
            index = input.index(after: index)
        }
        guard !digits.isEmpty, let id = UInt64(digits) else { return (nil, input) }
        return (id, String(input[index...]))
    }

    private static func parseEventArray(_ input: String) throws -> (String, [[String: Any]]) {
        guard let array = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [Any],
              let first = array.first as? String
        else { throw UUSignalError.malformedFrame("Socket.IO event array is empty") }
        let args = array.dropFirst().compactMap { $0 as? [String: Any] }
        return (first, args)
    }
}

/// gzip helpers for `gzip_sdp` soac fields.
public enum UUGzip {
    public static func compress(_ data: Data) -> Data {
        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return data }
        defer { deflateEnd(&stream) }
        var out = Data()
        data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.baseAddress!.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(raw.count)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                buffer.withUnsafeMutableBytes { buf in
                    stream.next_out = buf.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(buf.count)
                    status = deflate(&stream, Z_FINISH)
                    out.append(buf.baseAddress!.assumingMemoryBound(to: UInt8.self), count: buf.count - Int(stream.avail_out))
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK { out = data; break }
            }
        }
        return out
    }

    public static func decompress(_ data: Data, expectedSize: Int = 256 * 1024) -> Data {
        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        var status = inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return data }
        defer { inflateEnd(&stream) }
        var out = Data()
        data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.baseAddress!.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(raw.count)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                buffer.withUnsafeMutableBytes { buf in
                    stream.next_out = buf.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(buf.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    out.append(buf.baseAddress!.assumingMemoryBound(to: UInt8.self), count: buf.count - Int(stream.avail_out))
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR { break }
                if out.count > expectedSize { break }
            }
        }
        return out
    }
}

/// Reconnect state and lifecycle for a signaling WebSocket.
public actor UURemoteSignalingClient {
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    public private(set) var state: State = .disconnected
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var roomToken = ""
    private var signalServers: [String] = []
    private var selectedServer: String?
    private var connectTimeout: TimeInterval = 15
    private var reconnectDelay: TimeInterval = 2
    private var heartbeatTask: Task<Void, Never>?
    private var stopped = false

    /// Handlers for each inbound event name.
    public var onSignalEvent: ((String, [[String: Any]], [Data]) -> Void)?
    public var onStateChange: ((State) -> Void)?
    public var onSOAC: (([String: Any]) -> Void)?
    public var onControlAck: (([Any]) -> Void)?

    public func setOnSignalEvent(_ handler: @escaping (String, [[String: Any]], [Data]) -> Void) {
        onSignalEvent = handler
    }
    public func setOnStateChange(_ handler: @escaping (State) -> Void) {
        onStateChange = handler
    }
    public func setOnSOAC(_ handler: @escaping ([String: Any]) -> Void) {
        onSOAC = handler
    }
    public func setOnControlAck(_ handler: @escaping ([Any]) -> Void) {
        onControlAck = handler
    }

    /// Continuations waiting for the signal server's ack reply. Acks come
    /// back as `4[56]<id>[…]` text frames; `disconnect`/`handleDisconnect`
    /// resume every waiter with an error so callers never hang.
    private var pendingAcks: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var ackTimeouts: [UInt64: Task<Void, Never>] = [:]
    /// Upstream starts its ack ids at 10 and steps by 2 (signal.rs
    /// `next_ack`); the values are opaque to the server but we match anyway.
    private var nextAckID: UInt64 = 10

    /// A binary event whose JSON announced N attachments: its `{"_placeholder":true,"num":k}`
    /// values are hydrated once all N Engine.IO attachment frames arrive.
    private struct PendingBinaryEvent {
        var event: String
        var args: [[String: Any]]
        var expected: Int
        var attachments: [Data] = []
    }
    private var pendingBinaryEvent: PendingBinaryEvent?

    public init() {}

    /// Connects to the room's first available signal server.
    public func connect(roomConfig: UURoomConfig) async throws {
        guard !roomConfig.signalServers.isEmpty else {
            throw UUSignalError.invalidURL("no signal servers in room_config")
        }
        signalServers = roomConfig.signalServers
        roomToken = roomConfig.token
        connectTimeout = TimeInterval(roomConfig.timeout) / 1000
        reconnectDelay = TimeInterval(roomConfig.signalReconnectDelay) / 1000
        stopped = false

        var lastError: Error?
        for server in roomConfig.signalServers {
            do {
                try await openWebSocket(to: server, timeout: connectTimeout)
                selectedServer = server
                setState(.connected)
                startHeartbeat()
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? UUSignalError.transport("all signal servers failed")
    }

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }

    private func openWebSocket(to server: String, timeout: TimeInterval) async throws {
        // `signal_servers` entries may be bare hosts or full ws(s):// URLs.
        let base = server.contains("://") ? server : "wss://\(server)"
        guard let url = URL(string: "\(base.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/socket.io/?transport=websocket&EIO=4") else {
            throw UUSignalError.invalidURL(server)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(roomToken, forHTTPHeaderField: "X-NRD-AUTH")
        request.setValue("0", forHTTPHeaderField: "X-NRD-CONTROLLING")
        request.setValue(UUClientVersion.streamer, forHTTPHeaderField: "streamer_version")
        request.setValue(#"{"sdp_flags":{"gzip_sdp":true}}"#, forHTTPHeaderField: "streamer_flag")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: config)
        task = session?.webSocketTask(with: request)
        task?.maximumMessageSize = 4 * 1024 * 1024
        task?.resume()

        setState(.connecting)
        receiveNext()
        try await waitForConnect(timeout: timeout)
    }

    private func waitForConnect(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while state == .connecting {
            if Date() > deadline { throw UUSignalError.timeout("WebSocket open timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if case let .error(message) = state { throw UUSignalError.transport(message) }
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.string(text)):
                handleTextFrame(text)
                receiveNext()
            case let .success(.data(data)):
                handleBinaryFrame(data)
                receiveNext()
            case let .failure(error):
                Task { await self.handleDisconnect(error.localizedDescription) }
            @unknown default:
                receiveNext()
            }
        }
    }

    private func handleDisconnect(_ reason: String) {
        heartbeatTask?.cancel()
        // A receive failure racing `disconnect()` must not overwrite the
        // intentional `.disconnected` state with `.error`.
        if !stopped {
            setState(.error(reason))
        }
        failAllAcks(UUSignalError.transport(reason))
    }

    /// Resumes every pending ack continuation with an error — the callers
    /// must never hang once the transport is gone.
    private func failAllAcks(_ error: Error) {
        let waiters = pendingAcks
        pendingAcks.removeAll()
        let timers = ackTimeouts
        ackTimeouts.removeAll()
        for (_, timer) in timers { timer.cancel() }
        for (_, continuation) in waiters {
            continuation.resume(throwing: error)
        }
    }

    private func handleTextFrame(_ text: String) {
        do {
            let packet = try UUEngineIO.decode(text)
            switch packet {
            case .open:
                try sendText("40")
            case .close:
                Task { await handleDisconnect("server closed Engine.IO") }
            case let .ping(payload):
                try sendText(UUEngineIO.encodePong(payload))
            case .pong:
                break
            case let .message(socket):
                handleSocketPacket(socket)
            case .upgrade:
                break
            case .noop:
                break
            }
        } catch {
            Task { await handleDisconnect(error.localizedDescription) }
        }
    }

    /// Engine.IO attachment frames arrive as bare binary WebSocket frames
    /// after their `45<n>-…` JSON announced them. UU's SDK framing prefixes
    /// each attachment with `0x04`; uurc-web's transport patch strips it
    /// unconditionally, so we do the same.
    func handleBinaryFrame(_ data: Data) {
        var attachment = data
        if attachment.first == 0x04 { attachment = attachment.dropFirst(1) }
        guard var pending = pendingBinaryEvent else { return }
        pending.attachments.append(attachment)
        if pending.attachments.count >= pending.expected {
            pendingBinaryEvent = nil
            let hydrated = Self.hydrate(args: pending.args, attachments: pending.attachments)
            onSignalEvent?(pending.event, hydrated, pending.attachments)
            // Binary `soac` events (e.g. a `gzip_sdp` answer) also dispatch
            // to `onSOAC` — the same single hop plain events take, so a
            // soac reaches the driver exactly once on either wire form.
            if pending.event == "soac", let first = hydrated.first {
                onSOAC?(first)
            }
        } else {
            pendingBinaryEvent = pending
        }
    }

    /// Replaces every `{"_placeholder":true,"num":k}` leaf inside the event
    /// args with the base64 of attachment `k` — this is how `gzip_sdp` and
    /// other binary fields arrive, and the value the SOAC/SVP decoders read
    /// is exactly that base64 string.
    private static func hydrate(args: [[String: Any]], attachments: [Data]) -> [[String: Any]] {
        args.map { hydrate($0, attachments: attachments) as? [String: Any] ?? $0 }
    }

    private static func hydrate(_ value: Any, attachments: [Data]) -> Any {
        if let dict = value as? [String: Any] {
            if dict["_placeholder"] as? Bool == true,
               let num = dict["num"] as? Int,
               num >= 0, num < attachments.count {
                return attachments[num].base64EncodedString()
            }
            return dict.mapValues { hydrate($0, attachments: attachments) }
        }
        if let array = value as? [Any] {
            return array.map { hydrate($0, attachments: attachments) }
        }
        return value
    }

    func handleSocketPacket(_ packet: UUSocketPacket) {
        switch packet {
        case let .connect(namespace, _):
            setState(.connected)
        case .disconnect:
            Task { await handleDisconnect("Socket.IO namespace disconnected") }
        case let .event(_, _, event, args, _):
            onSignalEvent?(event, args, [])
            if event == "soac", let first = args.first {
                onSOAC?(first)
            }
        case let .binaryEvent(_, _, event, args, attachments):
            // Attachments follow on their own binary frames; hydrate the
            // `_placeholder` leaves once all of them arrived.
            pendingBinaryEvent = PendingBinaryEvent(event: event, args: args, expected: attachments)
        case let .ack(_, id, args):
            ackTimeouts.removeValue(forKey: id)?.cancel()
            if let continuation = pendingAcks.removeValue(forKey: id),
               let data = try? JSONSerialization.data(withJSONObject: args) {
                continuation.resume(returning: data)
            }
        case let .connectError(_, data):
            let message = data["message"] as? String ?? "connect_error"
            setState(.error(message))
            Task { await handleDisconnect(message) }
        }
    }

    private func sendText(_ text: String) throws {
        guard let task, state == .connected || state == .connecting else {
            throw UUSignalError.notConnected
        }
        task.send(.string(text)) { _ in }
    }

    private func sendBinary(_ data: Data) throws {
        guard let task, state == .connected || state == .connecting else {
            throw UUSignalError.notConnected
        }
        var prefixed = Data([0x04])
        prefixed.append(data)
        task.send(.data(prefixed)) { _ in }
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                try? await self.sendText("2")
            }
        }
    }

    /// Registers `continuation` for `id` and then sends `packet` — inside
    /// one task so the ack can never arrive between the two steps (the
    /// continuation closure itself is nonisolated).
    private func sendThenRegister(_ packet: @autoclosure () throws -> String, id: UInt64, continuation: CheckedContinuation<Data, Error>) {
        pendingAcks[id] = continuation
        do {
            try sendText(packet())
        } catch {
            pendingAcks.removeValue(forKey: id)
            ackTimeouts.removeValue(forKey: id)?.cancel()
            continuation.resume(throwing: error)
        }
    }

    /// Emits a Socket.IO event expecting an ack within `timeout` seconds.
    /// Returns the raw JSON ack args array (e.g. `["success", {…}]`);
    /// callers decode it themselves.
    public func emitWithAck(event: String, args: [[String: Any]], timeout: TimeInterval = 10) async throws -> Data {
        let id = nextAckID
        nextAckID += 2
        scheduleAckTimeout(id, timeout)
        return try await withCheckedThrowingContinuation { continuation in
            Task { await self.sendThenRegister(try UUEngineIO.encodeEvent(event, args: args, id: id), id: id, continuation: continuation) }
        }
    }

    /// Emits a Socket.IO event without waiting for its ack.
    public func emit(event: String, args: [[String: Any]], id: UInt64? = nil) throws {
        try sendText(UUEngineIO.encodeEvent(event, args: args, id: id))
    }

    private func scheduleAckTimeout(_ id: UInt64, _ timeout: TimeInterval) {
        ackTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.expireAck(id)
        }
    }

    private func expireAck(_ id: UInt64) {
        if let continuation = pendingAcks.removeValue(forKey: id) {
            continuation.resume(throwing: UUSignalError.timeout("signal ack \(id) timed out"))
        }
    }

    /// The Socket.IO `control` emit that asks the host to be controlled.
    ///
    /// Wire shape (upstream `Shape.control` + socket.io's own placeholder
    /// scheme): one text packet
    /// `451-<ackId>["control",{"app_control_id":…,"app_data":{"_placeholder":true,"num":0},"streamer_data":"<json>"}]`
    /// followed by one `0x04`-prefixed binary frame carrying the encoded
    /// ConnectOptions (`app_data` resolves to attachment 0 on the server).
    /// `streamer_data` is a JSON *string* of `{control_id, device_capability}`.
    ///
    /// Returns the raw ack args array (`["success", {result}]`).
    public func emitControl(appControlID: String, connectOptions: Data, streamerData: [String: Any], timeout: TimeInterval = 15) async throws -> Data {
        let id = nextAckID
        nextAckID += 2
        let streamerJSON = (try? JSONSerialization.data(withJSONObject: streamerData)).map {
            String(decoding: $0, as: UTF8.self)
        } ?? "{}"
        let header: [String: Any] = [
            "app_control_id": appControlID,
            "app_data": ["_placeholder": true, "num": 0],
            "streamer_data": streamerJSON,
        ]
        scheduleAckTimeout(id, timeout)
        return try await withCheckedThrowingContinuation { continuation in
            Task { await self.sendControlEmit(header: header, connectOptions: connectOptions, id: id, continuation: continuation) }
        }
    }

    /// `sendThenRegister` for the control emit: registers the ack, sends
    /// the `451-<id>["control",header]` text packet, then the `0x04`-prefixed
    /// ConnectOptions binary frame — in that order, all inside the actor.
    private func sendControlEmit(header: [String: Any], connectOptions: Data, id: UInt64, continuation: CheckedContinuation<Data, Error>) {
        pendingAcks[id] = continuation
        do {
            try sendText(UUEngineIO.encodeBinaryEvent("control", args: [header], id: id, attachmentCount: 1))
            try sendBinary(connectOptions)
        } catch {
            pendingAcks.removeValue(forKey: id)
            ackTimeouts.removeValue(forKey: id)?.cancel()
            continuation.resume(throwing: error)
        }
    }

    /// Sends a soac message (offer/answer/candidate/restart_ice): the arg is
    /// the `{client_id, data:{…}}` envelope upstream wraps every SOAC in.
    public func sendSOAC(_ soac: [String: Any]) throws {
        try emit(event: "soac", args: [soac])
    }

    /// Gracefully disconnects from the signal server, failing every pending
    /// ack so emit waiters do not hang.
    public func disconnect() {
        stopped = true
        heartbeatTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        pendingBinaryEvent = nil
        failAllAcks(UUSignalError.notConnected)
        setState(.disconnected)
    }
}
