//
//  VNCPixelFormat.swift
//  CatusshModule
//
//  RFB pixel formats: the one the client requests, the one the server
//  actually answers with, and the translation between a received pixel and
//  the canonical 32-bit BGRX value the framebuffer stores.
//

import Foundation

/// A 16-byte RFB `PixelFormat`.
struct VNCPixelFormat: Equatable, Sendable {
    var bitsPerPixel: UInt8
    var depth: UInt8
    var bigEndian: Bool
    var trueColour: Bool
    var redMax: UInt16
    var greenMax: UInt16
    var blueMax: UInt16
    var redShift: UInt8
    var greenShift: UInt8
    var blueShift: UInt8

    /// The format the client asks for: 32 bits per pixel, depth 24,
    /// little-endian, true colour — each pixel arrives as B, G, R, X bytes,
    /// which is exactly the framebuffer's storage.
    static let clientRequested = VNCPixelFormat(
        bitsPerPixel: 32, depth: 24,
        bigEndian: false, trueColour: true,
        redMax: 255, greenMax: 255, blueMax: 255,
        redShift: 16, greenShift: 8, blueShift: 0
    )

    var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    /// A "compressed pixel" (CPIXEL) is 3 bytes when the format is
    /// 32 bpp / depth 24 / true colour / all maxima 255; otherwise it is a
    /// full pixel. (ZRLE §6.6.4.)
    var cpixelByteCount: Int {
        if bitsPerPixel == 32, depth <= 24, trueColour,
           redMax == 255, greenMax == 255, blueMax == 255 { return 3 }
        return bytesPerPixel
    }

    // MARK: Wire codec

    /// Reads a pixel format from its 16-byte wire encoding.
    init?(wire data: Data) {
        guard data.count == 16 else { return nil }
        bitsPerPixel = data[0]
        depth = data[1]
        bigEndian = data[2] != 0
        trueColour = data[3] != 0
        redMax = data.readU16BE(at: 4)
        greenMax = data.readU16BE(at: 6)
        blueMax = data.readU16BE(at: 8)
        redShift = data[10]
        greenShift = data[11]
        blueShift = data[12]
        // 13...15 padding
    }

    init(bitsPerPixel: UInt8, depth: UInt8, bigEndian: Bool, trueColour: Bool,
         redMax: UInt16, greenMax: UInt16, blueMax: UInt16,
         redShift: UInt8, greenShift: UInt8, blueShift: UInt8)
    {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColour = trueColour
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// The 16-byte wire encoding.
    var wire: Data {
        var data = Data(capacity: 16)
        data.append(bitsPerPixel)
        data.append(depth)
        data.append(bigEndian ? 1 : 0)
        data.append(trueColour ? 1 : 0)
        data.appendU16BE(redMax)
        data.appendU16BE(greenMax)
        data.appendU16BE(blueMax)
        data.append(redShift)
        data.append(greenShift)
        data.append(blueShift)
        data.append(contentsOf: [0, 0, 0])
        return data
    }

    /// Translates one received pixel (in this format) into the canonical
    /// `0xAARRGGBB` word whose little-endian bytes are B, G, R, A — the
    /// framebuffer's layout. `nil` when the format is not a supported
    /// true-colour one.
    func translator() -> ((Data, Int) -> UInt32)? {
        guard trueColour else { return nil }
        let rMax = UInt32(redMax), gMax = UInt32(greenMax), bMax = UInt32(blueMax)
        guard rMax > 0, gMax > 0, bMax > 0 else { return nil }
        let rShift = redShift, gShift = greenShift, bShift = blueShift
        let littleEndian = !bigEndian
        let bpp = bytesPerPixel
        return { data, offset in
            var raw: UInt32 = 0
            if littleEndian {
                for i in 0 ..< bpp { raw |= UInt32(data[offset + i]) << (8 * i) }
            } else {
                for i in 0 ..< bpp { raw = (raw << 8) | UInt32(data[offset + i]) }
            }
            let r = ((raw >> rShift) & rMax) * 255 / rMax
            let g = ((raw >> gShift) & gMax) * 255 / gMax
            let b = ((raw >> bShift) & bMax) * 255 / bMax
            return 0xFF00_0000 | (r << 16) | (g << 8) | b
        }
    }
}

// MARK: - Big-endian wire helpers shared with the message codec

extension Data {
    /// Appends a UInt16 in network order.
    mutating func appendU16BE(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    /// Appends a UInt32 in network order.
    mutating func appendU32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    /// Appends an Int32 in network order.
    mutating func appendI32BE(_ value: Int32) {
        appendU32BE(UInt32(bitPattern: value))
    }

    /// Reads a UInt16 in network order at `offset`.
    func readU16BE(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    /// Reads a UInt32 in network order at `offset`.
    func readU32BE(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24) | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8) | UInt32(self[offset + 3])
    }

    /// Reads an Int32 in network order at `offset`.
    func readI32BE(at offset: Int) -> Int32 {
        Int32(bitPattern: readU32BE(at: offset))
    }
}
