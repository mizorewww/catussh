//
//  UURemotePortMapping.swift
//  CatusshModule
//
//  PortMappingFrame (protobuf field 27 on FILE_DATA_CHANNEL) and the bridge
//  that carries a TCP stream to a remote port through it — the same role
//  CloudflareAccessTunnel plays for SSH over Cloudflare. Mirrors
//  /tmp/uu-refs/uu-remote-linux/src/port_mapping.rs.
//

import Darwin
import Foundation
import NSRemoteShell

public enum UUPortMappingKind: UInt64, Sendable {
    case syn = 0
    case fin = 1
    case data = 2
    case synAck = 3
    case dataAck = 4
}

/// One PortMappingFrame: `{1:session_id, 2:rule_id, 3:stream_id, 4:type, 5:payload}`.
/// ID fields may arrive as either varint or bytes and must be echoed back in the
/// same wire type.
public enum UUPortMappingID: Equatable, Hashable, Sendable {
    case varint(UInt64)
    case bytes(Data)
    case missing
}

public struct UUPortMappingFrame: Equatable, Sendable {
    public var sessionID: UUPortMappingID = .missing
    public var ruleID: UUPortMappingID = .missing
    public var streamID: UUPortMappingID = .missing
    public var type: UUPortMappingKind = .syn
    public var payload = Data()

    public init() {}

    public func encode() -> Data {
        var out = Data()
        Self.encodeID(sessionID, number: 1, into: &out)
        Self.encodeID(ruleID, number: 2, into: &out)
        Self.encodeID(streamID, number: 3, into: &out)
        if type != .syn { UUProtobufWriter.pushVarintField(4, type.rawValue, into: &out) }
        if !payload.isEmpty { UUProtobufWriter.pushBytesField(5, payload, into: &out) }
        return out
    }

    public init(decoding data: Data) {
        guard let fields = try? UUWire.decode(data) else { return }
        for field in fields {
            switch field.number {
            case 1: sessionID = Self.id(of: field)
            case 2: ruleID = Self.id(of: field)
            case 3: streamID = Self.id(of: field)
            case 4:
                if case let .varint(v) = field.value { type = UUPortMappingKind(rawValue: v) ?? .syn }
            case 5:
                if case let .bytes(b) = field.value { payload = b }
            default: break
            }
        }
    }

    private static func id(of field: UUWireField) -> UUPortMappingID {
        switch field.value {
        case let .varint(v): .varint(v)
        case let .bytes(b): .bytes(b)
        default: .missing
        }
    }

    private static func encodeID(_ id: UUPortMappingID, number: Int, into out: inout Data) {
        switch id {
        case let .varint(v):
            UUProtobufWriter.pushVarintField(number, v, into: &out)
        case let .bytes(b):
            UUProtobufWriter.pushBytesField(number, b, into: &out)
        case .missing:
            break
        }
    }
}

public enum UUPortMappingEnvelope {
    /// Wraps a PortMappingFrame into a Message field-27 envelope.
    public static func wrap(frame: UUPortMappingFrame, sequence: UInt64, timestamp: UInt64) -> Data {
        UUControlProtocol.envelope(
            sequence: sequence,
            timestamp: timestamp,
            fieldNumber: UUControlField.portMappingFrame,
            body: frame.encode()
        )
    }

    /// Extracts the PortMappingFrame body from a field-27 envelope; nil when
    /// the envelope carries a different message.
    public static func unwrap(_ data: Data) -> UUPortMappingFrame? {
        guard let inbound = UUControlProtocol.decodeInbound(data),
              inbound.field.number == UUControlField.portMappingFrame,
              case let .bytes(body) = inbound.field.value
        else { return nil }
        return UUPortMappingFrame(decoding: body)
    }
}

public struct UUPortMappingSYN: Equatable, Sendable {
    public var version: UInt64 = 1
    public var targetHost: String = ""
    public var targetPort: UInt16 = 0

    public init(targetHost: String, targetPort: UInt16) {
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    public func encode() -> Data {
        #"{"version":\#(version),"target_host":"\#(targetHost)","target_port":\#(targetPort)}"#.data(using: .utf8)!
    }

    public init?(decoding data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let host = (json["target_host"] as? String ?? json["targetHost"] as? String)?.trimmingCharacters(in: .whitespaces),
              !host.isEmpty
        else { return nil }
        guard let port = (json["target_port"] as? NSNumber)?.uint16Value ?? (json["targetPort"] as? NSNumber)?.uint16Value,
              port > 0
        else { return nil }
        targetHost = host
        targetPort = port
    }
}

public struct UUPortMappingSYNACK: Equatable, Sendable {
    public var version: UInt64 = 1
    public var ok = false
    public var error: String?

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }

    public func encode() -> Data {
        var dict: [String: Any] = ["version": version, "ok": ok]
        if let error { dict["error"] = error }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    public init?(decoding data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? UInt64,
              let ok = json["ok"] as? Bool
        else { return nil }
        self.version = version
        self.ok = ok
        error = json["error"] as? String
    }
}

/// Bridges one local socketpair fd to a remote TCP stream over the UU Remote
/// PortMapping channel, giving libssh2 a plain socket to read and write.
public final class UURemotePortMappingTunnel: NSObject, @unchecked Sendable {
    public struct Failure: Error, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public enum StreamKey: Hashable, Sendable {
        case ids(session: UUPortMappingID, rule: UUPortMappingID, stream: UUPortMappingID)
        public var description: String {
            switch self {
            case let .ids(session, rule, stream):
                return "\(session):\(rule):\(stream)"
            }
        }
    }

    /// Sends complete field-27 envelopes on FILE_DATA_CHANNEL.
    public typealias OutboundHandler = @Sendable (Data) -> Void

    private var sendEnvelope: OutboundHandler
    private let sendEnvelopeLock = NSLock()
    private var outboundSequence: UInt64 = 0
    private let outboundLock = NSLock()

    /// Open streams keyed by their frame identity triple.
    private struct Stream {
        var key: StreamKey
        var localFD: Int32
        var readerThread: Thread?
        var closed = false
    }

    private var streams: [StreamKey: Stream] = [:]
    private let streamsLock = NSLock()

    /// The completion handlers waiting for a SYN_ACK for each stream.
    private var pendingSYN: [StreamKey: (Result<UUPortMappingSYNACK, Failure>) -> Void] = [:]
    private let pendingLock = NSLock()

    public init(sendEnvelope: @escaping OutboundHandler) {
        self.sendEnvelope = sendEnvelope
    }

    /// Replaces the envelope sink; used when the tunnel is built before its
    /// channel sender exists (self-reference in the owning driver's init).
    public func setSendEnvelope(_ handler: @escaping OutboundHandler) {
        sendEnvelopeLock.withLock { sendEnvelope = handler }
    }

    /// Sends a frame on FILE_DATA_CHANNEL wrapped in the field-27 envelope.
    private func send(_ frame: UUPortMappingFrame) {
        outboundLock.withLock {
            outboundSequence += 1
            let ts = UInt64(Date().timeIntervalSince1970)
            let sink = sendEnvelopeLock.withLock { sendEnvelope }
            sink(UUPortMappingEnvelope.wrap(frame: frame, sequence: outboundSequence, timestamp: ts))
        }
    }

    /// Handles an incoming PortMappingFrame decoded from FILE_DATA_CHANNEL.
    public func handle(frame: UUPortMappingFrame) {
        let key = StreamKey.ids(session: frame.sessionID, rule: frame.ruleID, stream: frame.streamID)
        switch frame.type {
        case .syn:
            // We are the viewer side: the host sends us SYN for its own local
            // forwards; our SYN is answered by SYN_ACK below.
            break
        case .synAck:
            guard let ack = UUPortMappingSYNACK(decoding: frame.payload) else { return }
            pendingLock.withLock {
                if let handler = pendingSYN.removeValue(forKey: key) {
                    handler(.success(ack))
                }
            }
        case .data:
            streamsLock.withLock {
                if var stream = streams[key], !stream.closed {
                    let fd = stream.localFD
                    var data = frame.payload
                    let written = data.withUnsafeBytes { raw -> Bool in
                        var offset = 0
                        while offset < raw.count {
                            let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                            if n < 0, errno == EINTR { continue }
                            guard n > 0 else { return false }
                            offset += n
                        }
                        return true
                    }
                    if !written { stream.closed = true }
                }
            }
        case .fin:
            close(key, sendFIN: false)
        case .dataAck:
            break
        }
    }

    /// Opens a stream and returns the socketpair end for libssh2 to use.
    /// Blocks the calling thread until SYN_ACK arrives or `timeout` expires.
    public func openStream(targetHost: String, targetPort: UInt16, timeout: TimeInterval) -> Result<Int32, Failure> {
        let sessionID = nextRuleID()
        let ruleID = nextRuleID()
        let streamID = nextStreamID()
        let key = StreamKey.ids(session: .varint(sessionID), rule: .varint(ruleID), stream: .varint(streamID))

        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            return .failure(Failure("Could not make a socket pair for the UU Remote tunnel (errno \(errno))."))
        }
        for fd in pair {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<UUPortMappingSYNACK, Failure> = .failure(Failure("UU Remote port mapping SYN_ACK timed out."))
        pendingLock.withLock {
            pendingSYN[key] = { result in
                outcome = result
                semaphore.signal()
            }
        }

        var syn = UUPortMappingFrame()
        syn.sessionID = .varint(sessionID)
        syn.ruleID = .varint(ruleID)
        syn.streamID = .varint(streamID)
        syn.type = .syn
        syn.payload = UUPortMappingSYN(targetHost: targetHost, targetPort: targetPort).encode()
        send(syn)

        let inTime = semaphore.wait(timeout: .now() + timeout) == .success
        guard inTime else {
            pendingLock.withLock { pendingSYN.removeValue(forKey: key) }
            Darwin.close(pair[0]); Darwin.close(pair[1])
            return .failure(Failure("UU Remote port mapping SYN_ACK timed out."))
        }
        switch outcome {
        case let .failure(failure):
            Darwin.close(pair[0]); Darwin.close(pair[1])
            return .failure(failure)
        case let .success(ack):
            guard ack.ok else {
                Darwin.close(pair[0]); Darwin.close(pair[1])
                return .failure(Failure(ack.error ?? "UU Remote port mapping was rejected by the host."))
            }
        }

        streamsLock.withLock {
            streams[key] = Stream(key: key, localFD: pair[1])
        }

        let fd = pair[1]
        let reader = Thread { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                var data = UUPortMappingFrame()
                data.sessionID = .varint(sessionID)
                data.ruleID = .varint(ruleID)
                data.streamID = .varint(streamID)
                data.type = .data
                data.payload = Data(buffer[0 ..< count])
                self.send(data)
            }
            self.close(key, sendFIN: true)
        }
        reader.name = "me.mizorewww.uu-portmap.\(key.description)"
        reader.start()

        streamsLock.withLock { streams[key]?.readerThread = reader }
        return .success(pair[0])
    }

    private var ruleCounter: UInt64 = 1
    private var streamCounter: UInt64 = 1
    private let counterLock = NSLock()
    private func nextRuleID() -> UInt64 {
        counterLock.withLock { defer { ruleCounter += 1 }; return ruleCounter }
    }
    private func nextStreamID() -> UInt64 {
        counterLock.withLock { defer { streamCounter += 1 }; return streamCounter }
    }

    /// Closes one stream: the writer thread is unblocked and a FIN is sent
    /// when requested.
    public func close(_ key: StreamKey, sendFIN: Bool) {
        let removed = streamsLock.withLock { streams.removeValue(forKey: key) }
        if let stream = removed {
            if !stream.closed {
                Darwin.shutdown(stream.localFD, SHUT_RDWR)
            }
            if sendFIN {
                var fin = UUPortMappingFrame()
                if case let .ids(session, rule, streamID) = key {
                    fin.sessionID = session
                    fin.ruleID = rule
                    fin.streamID = streamID
                }
                fin.type = .fin
                send(fin)
            }
            stream.readerThread?.cancel()
            Darwin.close(stream.localFD)
        }
    }

    /// Closes every open stream when the peer connection ends.
    public func shutdown() {
        let keys = streamsLock.withLock { Array(streams.keys) }
        for key in keys { close(key, sendFIN: false) }
        pendingLock.withLock {
            for handler in pendingSYN.values {
                handler(.failure(Failure("UU Remote tunnel shut down.")))
            }
            pendingSYN.removeAll()
        }
    }
}

// MARK: - The shell's side

private nonisolated(unsafe) let uuTunnelFailureKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

public extension NSRemoteShell {
    /// Why the last connection through UU Remote could not be made, for the
    /// person; nil after a connection that got through, or one made over TCP.
    var uuTunnelFailure: String? {
        get { objc_getAssociatedObject(self, uuTunnelFailureKey) as? String }
        set { objc_setAssociatedObject(self, uuTunnelFailureKey, newValue, .OBJC_ASSOCIATION_COPY) }
    }

    /// Has the shell reach the machine through an active UU Remote session's
    /// port-mapping stream. The tunnel must be bound by `UURemoteDriver` before
    /// any SSH connection is attempted.
    internal func applyUUTransport(for machine: RDMachine) {
        uuTunnelFailure = nil
        let deviceID = machine.uuDeviceID.isEmpty ? machine.remoteAddress : machine.uuDeviceID
        setupConnectionSocketProvider { [weak self] host, port, timeout in
            guard let tunnel = UURemotePortMappingTunnelProvider.shared.tunnel(for: deviceID) else {
                self?.uuTunnelFailure = "No active UU Remote session for device \(deviceID). Start remote desktop first."
                return -1
            }
            let targetPort = UInt16(port.intValue > 0 ? port.intValue : 22)
            // `remoteAddress` on a UU machine is the device id, not an IP:
            // the port-mapped service (sshd) lives on the remote host's own
            // loopback. Only forward a real dotted address when one exists.
            let targetHost = (host == deviceID || !host.contains(".")) ? "127.0.0.1" : host
            let result = tunnel.openStream(
                targetHost: targetHost,
                targetPort: targetPort,
                timeout: max(timeout.doubleValue, 15)
            )
            switch result {
            case let .success(fd):
                self?.uuTunnelFailure = nil
                return fd
            case let .failure(failure):
                self?.uuTunnelFailure = failure.message
                return -1
            }
        }
    }
}

/// The single registry that hands the active UU Remote port-mapping tunnel to
/// `NSRemoteShell` when a machine's transport is `uuRemote`.
public final class UURemotePortMappingTunnelProvider: @unchecked Sendable {
    public static let shared = UURemotePortMappingTunnelProvider()

    private let lock = NSLock()
    private var tunnels: [String: UURemotePortMappingTunnel] = [:]

    private init() {}

    /// Binds a tunnel to a device ID while a session is open.
    public func register(_ tunnel: UURemotePortMappingTunnel, for deviceID: String) {
        lock.withLock { tunnels[deviceID] = tunnel }
    }

    /// Removes the binding when a session ends.
    public func unregister(for deviceID: String) {
        lock.withLock { tunnels.removeValue(forKey: deviceID) }
    }

    /// The tunnel bound to a device, or nil when no UU Remote session is open.
    public func tunnel(for deviceID: String) -> UURemotePortMappingTunnel? {
        lock.withLock { tunnels[deviceID] }
    }
}
