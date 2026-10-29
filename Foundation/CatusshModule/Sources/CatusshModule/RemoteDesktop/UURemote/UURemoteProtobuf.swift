//
//  UURemoteProtobuf.swift
//  CatusshModule
//
//  Dependency-free Protocol Buffers wire reader and writer for the UU Remote
//  streamer control channels. Mirrors /tmp/uu-refs/uu-remote-linux/src/protocol.rs
//  and /tmp/uu-refs/uurc-web/shared/src/streamer/internal/protobufWire.ts.
//

import Foundation

public enum UUWireType: UInt8, Sendable {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

public enum UUWireValue: Equatable, Sendable {
    case varint(UInt64)
    case fixed64(Data)
    case bytes(Data)
    case fixed32(Data)
}

public struct UUWireField: Equatable, Sendable {
    public var number: UInt32
    public var value: UUWireValue
    public init(number: UInt32, value: UUWireValue) {
        self.number = number
        self.value = value
    }
}

public enum UUWireError: Error, Equatable, Sendable {
    case truncated
    case varintOverflow
    case invalidField
    case unsupportedWireType(UInt8)
    case lengthExceeded
}

public enum UUWire {
    /// Decodes a complete protobuf message into fields, preserving opaque
    /// nested payloads. Rejects deprecated groups and malformed field keys.
    public static func decode(_ input: Data) throws -> [UUWireField] {
        var offset = 0
        var fields: [UUWireField] = []
        while offset < input.count {
            let key = try readVarint(input, &offset)
            let number = key >> 3
            guard number > 0, number <= 0x1FFF_FFFF else {
                throw UUWireError.invalidField
            }
            let wire = UInt8(key & 7)
            let value: UUWireValue
            switch wire {
            case 0:
                value = .varint(try readVarint(input, &offset))
            case 1:
                value = .fixed64(try take(input, &offset, 8))
            case 2:
                let length = try readVarint(input, &offset)
                guard length <= UInt64(input.count - offset) else { throw UUWireError.truncated }
                guard length <= UInt64(Int.max) else { throw UUWireError.lengthExceeded }
                value = .bytes(try take(input, &offset, Int(length)))
            case 5:
                value = .fixed32(try take(input, &offset, 4))
            default:
                throw UUWireError.unsupportedWireType(wire)
            }
            fields.append(UUWireField(number: UInt32(number), value: value))
        }
        return fields
    }

    /// Structure-only rendering for diagnostics: field numbers, wire types,
    /// lengths and small varints. String/byte contents are never rendered.
    public static func wireShape(_ data: Data, depth: Int = 3) -> String {
        guard let fields = try? decode(data) else {
            return "bytes(\(data.count))"
        }
        let parts = fields.map { field -> String in
            switch field.value {
            case let .varint(v) where v == .max: return "\(field.number)=-1"
            case let .varint(v) where v <= 0xFFFF: return "\(field.number)=\(v)"
            case .varint: return "\(field.number)=big"
            case .fixed32: return "\(field.number):f32"
            case .fixed64: return "\(field.number):f64"
            case let .bytes(b): return "\(field.number):\(bytesShape(b, depth: depth))"
            }
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private static func bytesShape(_ bytes: Data, depth: Int) -> String {
        if !bytes.isEmpty, let text = String(data: bytes, encoding: .utf8),
           text.allSatisfy({ !$0.isASCII || !$0.unicodeScalars.first!.isASCII || UInt8($0.unicodeScalars.first!.value) >= 0x20 })
        {
            return "str(\(bytes.count))"
        }
        if depth > 0, !bytes.isEmpty,
           let fields = try? decode(bytes), !fields.isEmpty,
           fields.allSatisfy({ (1 ... 128).contains($0.number) })
        {
            return wireShape(bytes, depth: depth - 1)
        }
        return "bytes(\(bytes.count))"
    }
}

/// The writer half: appends protobuf fields to an output buffer.
public enum UUProtobufWriter {
    public static func pushVarint(_ value: UInt64, into out: inout Data) {
        var remaining = value
        while remaining >= 0x80 {
            out.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        out.append(UInt8(remaining))
    }

    /// Two's complement encoding for negative 32-bit values.
    public static func pushInt32(_ value: Int32, into out: inout Data) {
        pushVarint(UInt64(bitPattern: Int64(value)), into: &out)
    }

    public static func pushFieldKey(_ field: Int, wire: UUWireType, into out: inout Data) {
        pushVarint(UInt64(field << 3) | UInt64(wire.rawValue), into: &out)
    }

    public static func pushVarintField(_ field: Int, _ value: UInt64, into out: inout Data) {
        pushFieldKey(field, wire: .varint, into: &out)
        pushVarint(value, into: &out)
    }

    public static func pushInt32Field(_ field: Int, _ value: Int32, into out: inout Data) {
        pushFieldKey(field, wire: .varint, into: &out)
        pushInt32(value, into: &out)
    }

    public static func pushStringField(_ field: Int, _ value: String, into out: inout Data) {
        let encoded = Data(value.utf8)
        pushFieldKey(field, wire: .lengthDelimited, into: &out)
        pushVarint(UInt64(encoded.count), into: &out)
        out.append(encoded)
    }

    public static func pushMessageField(_ field: Int, _ payload: Data, into out: inout Data) {
        pushFieldKey(field, wire: .lengthDelimited, into: &out)
        pushVarint(UInt64(payload.count), into: &out)
        out.append(payload)
    }

    public static func pushBytesField(_ field: Int, _ value: Data, into out: inout Data) {
        pushFieldKey(field, wire: .lengthDelimited, into: &out)
        pushVarint(UInt64(value.count), into: &out)
        out.append(value)
    }
}

private func readVarint(_ input: Data, _ offset: inout Int) throws -> UInt64 {
    var result: UInt64 = 0
    for shift in stride(from: 0, through: 70, by: 7) {
        guard offset < input.count else { throw UUWireError.truncated }
        let byte = input[offset]
        offset += 1
        if shift == 63, byte > 1 { throw UUWireError.varintOverflow }
        result |= UInt64(byte & 0x7F) << shift
        if byte & 0x80 == 0 { return result }
    }
    throw UUWireError.varintOverflow
}

private func take(_ input: Data, _ offset: inout Int, _ length: Int) throws -> Data {
    let end = offset + length
    guard end <= input.count else { throw UUWireError.truncated }
    defer { offset = end }
    return input.subdata(in: offset ..< end)
}
