//
//  VNCMessages.swift
//  CatusshModule
//
//  RFB 3.3 / 3.7 / 3.8 wire structures: version banner, security
//  negotiation, init handshake, the client-to-server messages the driver
//  sends, and the server-to-client message/rectangle headers the reader
//  loop parses. Pure encoding/decoding — the socket lives elsewhere.
//

import Foundation

enum VNCWire {
    /// The 12-byte protocol banner, e.g. "RFB 003.008\n".
    static func banner(major: Int, minor: Int) -> Data {
        Data(String(format: "RFB %03d.%03d\n", major, minor).utf8)
    }

    /// Parses "RFB 003.008\n".
    static func parseBanner(_ data: Data) -> (major: Int, minor: Int)? {
        guard data.count == 12,
              let text = String(data: data, encoding: .ascii),
              text.hasPrefix("RFB "), text.hasSuffix("\n")
        else { return nil }
        let major = Int(text.dropFirst(4).prefix(3)), minor = Int(text.dropFirst(8).prefix(3))
        guard let major, let minor else { return nil }
        return (major, minor)
    }

    // MARK: Security

    enum SecurityType: UInt8, Sendable {
        case invalid = 0
        case none = 1
        case vncAuth = 2
        // RA2(5), RA2ne(6), Tight(16), Ultra(19), TLS(18), VeNCrypt(19),
        // SASL(20), ARD(30), MS Logon(113) — known but unsupported here.
    }

    // MARK: Client → server messages

    static func clientInit(shared: Bool) -> Data {
        Data([shared ? 1 : 0])
    }

    static func setPixelFormat(_ format: VNCPixelFormat) -> Data {
        var data = Data(capacity: 20)
        data.append(0) // message type 0
        data.append(contentsOf: [0, 0, 0]) // padding
        data.append(format.wire)
        return data
    }

    static func setEncodings(_ encodings: [Int32]) -> Data {
        var data = Data(capacity: 4 + encodings.count * 4)
        data.append(2) // message type 2
        data.append(0) // padding
        data.appendU16BE(UInt16(encodings.count))
        for encoding in encodings { data.appendI32BE(encoding) }
        return data
    }

    static func framebufferUpdateRequest(incremental: Bool, x: UInt16, y: UInt16, width: UInt16, height: UInt16) -> Data {
        var data = Data(capacity: 10)
        data.append(3) // message type 3
        data.append(incremental ? 1 : 0)
        data.appendU16BE(x)
        data.appendU16BE(y)
        data.appendU16BE(width)
        data.appendU16BE(height)
        return data
    }

    static func keyEvent(down: Bool, keySym: UInt32) -> Data {
        var data = Data(capacity: 8)
        data.append(4) // message type 4
        data.append(down ? 1 : 0)
        data.append(contentsOf: [0, 0]) // padding
        data.appendU32BE(keySym)
        return data
    }

    static func pointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) -> Data {
        var data = Data(capacity: 6)
        data.append(5) // message type 5
        data.append(buttonMask)
        data.appendU16BE(x)
        data.appendU16BE(y)
        return data
    }

    static func clientCutText(_ text: String) -> Data {
        // RFB cut text is ISO-8859-1; characters outside it degrade to '?'.
        let bytes = text.latin1Bytes
        var data = Data(capacity: 8 + bytes.count)
        data.append(6) // message type 6
        data.append(contentsOf: [0, 0, 0]) // padding
        data.appendU32BE(UInt32(bytes.count))
        data.append(contentsOf: bytes)
        return data
    }

    // MARK: Server → client messages

    enum ServerMessageType: UInt8 {
        case framebufferUpdate = 0
        case setColourMapEntries = 1
        case bell = 2
        case serverCutText = 3
    }

    /// The header of one FramebufferUpdate rectangle (position, size,
    /// encoding) — the encoding-specific payload follows.
    struct RectangleHeader: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var encoding: Int32

        static let wireLength = 12

        init?(wire data: Data) {
            guard data.count >= Self.wireLength else { return nil }
            x = Int(data.readU16BE(at: 0))
            y = Int(data.readU16BE(at: 2))
            width = Int(data.readU16BE(at: 4))
            height = Int(data.readU16BE(at: 6))
            encoding = data.readI32BE(at: 8)
        }
    }

    /// Parses a ServerInit payload (without the message framing):
    /// width, height, pixel format, desktop name.
    struct ServerInit: Equatable {
        var width: Int
        var height: Int
        var pixelFormat: VNCPixelFormat
        var desktopName: String
    }

    static func parseServerInit(data: Data) -> ServerInit? {
        guard data.count >= 24,
              let format = VNCPixelFormat(wire: data.subdata(in: 4 ..< 20))
        else { return nil }
        let nameLength = Int(data.readU32BE(at: 20))
        guard data.count >= 24 + nameLength else { return nil }
        let nameData = data.subdata(in: 24 ..< 24 + nameLength)
        let name = String(data: nameData, encoding: .utf8)
            ?? String(data: nameData, encoding: .isoLatin1)
            ?? ""
        return ServerInit(
            width: Int(data.readU16BE(at: 0)),
            height: Int(data.readU16BE(at: 2)),
            pixelFormat: format,
            desktopName: name
        )
    }

    // MARK: Encodings

    enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case rre = 2
        case hextile = 5
        case zrle = 16
        /// Pseudo: the host draws the cursor itself; the rectangle is its
        /// hotspot + shape + mask.
        case cursor = -239
        /// Pseudo: the host's framebuffer changed size.
        case desktopSize = -223
    }

    /// The encodings the client advertises, most-preferred last per spec
    /// ordering convention (order is not significant for negotiation).
    static let clientEncodings: [Int32] = [
        Encoding.raw.rawValue,
        Encoding.copyRect.rawValue,
        Encoding.rre.rawValue,
        Encoding.hextile.rawValue,
        Encoding.zrle.rawValue,
        Encoding.cursor.rawValue,
        Encoding.desktopSize.rawValue,
    ]
}

extension String {
    /// The string as ISO-8859-1 bytes, mapping unrepresentable scalars to '?'.
    var latin1Bytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(utf8.count)
        for scalar in unicodeScalars {
            bytes.append(scalar.value <= 0xFF ? UInt8(scalar.value) : UInt8(ascii: "?"))
        }
        return bytes
    }
}
