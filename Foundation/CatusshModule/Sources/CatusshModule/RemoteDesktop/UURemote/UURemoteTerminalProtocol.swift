//
//  UURemoteTerminalProtocol.swift
//  CatusshModule
//
//  TERM frame codec for the BINARY_DATA_CHANNEL. Mirrors
//  /tmp/uu-refs/uu-remote-linux/src/terminal.rs (the official Mac host
//  UURemoteServer codec at 0x1001a7834 decode / 0x1001a7480 encode).
//

import Foundation

public enum UUTerminalKind: UInt8, CaseIterable, Sendable {
    case open = 1
    case stdin = 2
    case resize = 3
    case close = 4
    case stdout = 5
    case exit = 6
    case signal = 7
    case error = 8
    case listReq = 9
    case listResp = 10
    case killReq = 11
    case killResp = 12
    case openResp = 13
    case unlockReq = 14
    case unlockResp = 15
    case detach = 16
}

/// One TERM frame on BINARY_DATA_CHANNEL: a 16-byte fixed header plus payload.
public struct UUTerminalFrame: Equatable, Sendable {
    public static let magic = Data("TERM".utf8)
    public static let version: UInt8 = 1
    public static let headerSize = 16
    public static let maxPayload = 0x10_0000

    public var kind: UUTerminalKind
    public var flags: [UInt8]
    public var sessionID: UInt32
    public var payload: Data

    public init(kind: UUTerminalKind, sessionID: UInt32, payload: Data = Data(), flags: [UInt8] = [0, 0]) {
        self.kind = kind
        self.sessionID = sessionID
        self.payload = payload
        self.flags = flags.count == 2 ? flags : [0, 0]
    }

    public func encode() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append(Self.magic)
        out.append(Self.version)
        out.append(kind.rawValue)
        out.append(contentsOf: flags)
        var session = sessionID.littleEndian
        out.append(Data(bytes: &session, count: 4))
        var length = UInt32(payload.count).littleEndian
        out.append(Data(bytes: &length, count: 4))
        out.append(payload)
        return out
    }

    /// Decodes exactly one complete frame; nil on malformed input.
    public static func decode(_ data: Data) -> UUTerminalFrame? {
        guard data.count >= headerSize, data.prefix(4) == magic else { return nil }
        guard let kind = UUTerminalKind(rawValue: data[5]), (1 ... 16).contains(kind.rawValue) else { return nil }
        let session = data.subdata(in: 8 ..< 12).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let length = Int(data.subdata(in: 12 ..< 16).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        guard length <= maxPayload, data.count == headerSize + length else { return nil }
        return UUTerminalFrame(
            kind: kind,
            sessionID: session,
            payload: data.subdata(in: headerSize ..< headerSize + length),
            flags: [data[6], data[7]]
        )
    }

    public static func isFrame(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == magic
    }
}

/// Convenience builders for the JSON control payloads TERM uses.
public enum UUTerminalJSON {
    /// OPEN(1) body: `{cols,rows,shell,"option":"none"}`.
    public static func open(cols: Int, rows: Int, shell: String = "/bin/zsh", option: String = "none") -> Data {
        let json = #"{"cols":\#(cols),"rows":\#(rows),"shell":"\#(shell)","option":"\#(option)"}"#
        return json.data(using: .utf8)!
    }

    /// RESIZE(3) body: `{cols,rows}`.
    public static func resize(cols: Int, rows: Int) -> Data {
        #"{"cols":\#(cols),"rows":\#(rows)}"#.data(using: .utf8)!
    }

    /// SIGNAL(7) body: `{"signal":"SIGKILL"}`.
    public static func signal(_ name: String) -> Data {
        #"{"signal":"\#(name)"}"#.data(using: .utf8)!
    }

    /// Parses OPEN_RESP(13): `{code,message[,session_id]}`.
    public static func decodeOpenResponse(_ payload: Data) -> (code: Int, message: String, sessionID: UInt32?)? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let code = json["code"] as? Int
        else { return nil }
        let message = json["message"] as? String ?? ""
        let sid = (json["session_id"] as? NSNumber)?.uint32Value
        return (code, message, sid)
    }

    /// Parses LIST_RESP(10): bare array `[{session_id,name,shell,state,created_at_ms}]`.
    public static func decodeListResponse(_ payload: Data) -> [[String: Any]]? {
        try? JSONSerialization.jsonObject(with: payload) as? [[String: Any]]
    }

    /// Parses EXIT(6): `{exit_code}`.
    public static func decodeExit(_ payload: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let code = json["exit_code"] as? Int
        else { return nil }
        return code
    }
}
