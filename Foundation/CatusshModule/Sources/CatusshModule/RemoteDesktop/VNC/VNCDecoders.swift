//
//  VNCDecoders.swift
//  CatusshModule
//
//  FramebufferUpdate rectangle decoders: Raw, CopyRect, RRE, Hextile,
//  ZRLE, and the Cursor and DesktopSize pseudo-encodings. Each decoder
//  pulls its payload out of a `VNCByteChannel` (the socket in production,
//  a memory buffer in tests) and paints into the framebuffer.
//

import CoreGraphics
import Foundation

enum VNCDecodeError: Error, Equatable {
    case unsupportedEncoding(Int32)
    case malformed(String)
}

enum VNCDecoders {
    /// The context one update shares: the pixel translator for the
    /// server's format and the framebuffer being painted.
    struct Context {
        var framebuffer: VNCFramebuffer
        /// Server pixel -> canonical `0xAARRGGBB` word.
        var pixelTranslator: (Data, Int) -> UInt32
        /// Full pixel byte count in the server's format.
        var bytesPerPixel: Int
        /// CPIXEL byte count (ZRLE): 3 for 32bpp/depth24/all-255 formats,
        /// otherwise `bytesPerPixel`.
        var cpixelByteCount: Int
        /// Where the absent byte of a CPIXEL goes when padding to a full
        /// pixel: big-endian wire order drops the leading byte.
        var cpixelPadsAtEnd = true
        /// The connection's persistent ZRLE inflate stream, when ZRLE was
        /// negotiated.
        var zlib: VNCZlibStream?
    }

    /// Reads one full pixel in the server's format and translates it.
    private static func readFullPixel(from source: VNCByteChannel, using context: Context) throws -> UInt32 {
        let data = try source.read(exactly: context.bytesPerPixel)
        return context.pixelTranslator(data, 0)
    }

    /// Decodes one rectangle payload for `header` into the framebuffer.
    static func decode(_ header: VNCWire.RectangleHeader, from source: VNCByteChannel, context: Context) throws {
        switch VNCWire.Encoding(rawValue: header.encoding) {
        case .raw:
            try raw(header, from: source, context: context)
        case .copyRect:
            try copyRect(header, from: source, context: context)
        case .rre:
            try rre(header, from: source, context: context)
        case .hextile:
            try hextile(header, from: source, context: context)
        case .zrle:
            try zrle(header, from: source, context: context)
        case .cursor, .desktopSize, nil:
            throw VNCDecodeError.unsupportedEncoding(header.encoding)
        }
    }

    // MARK: - Raw (encoding 0)

    static func raw(_ header: VNCWire.RectangleHeader, from source: VNCByteChannel, context: Context) throws {
        let bytes = header.width * header.height * context.bytesPerPixel
        let data = try source.read(exactly: bytes)
        var line: [UInt32] = []
        line.reserveCapacity(header.width * header.height)
        for index in stride(from: 0, to: data.count, by: context.bytesPerPixel) {
            line.append(context.pixelTranslator(data, index))
        }
        context.framebuffer.putRun(x: header.x, y: header.y, width: header.width, pixels: line[...])
    }

    // MARK: - CopyRect (encoding 1)

    static func copyRect(_ header: VNCWire.RectangleHeader, from source: VNCByteChannel, context: Context) throws {
        let position = try source.read(exactly: 4)
        context.framebuffer.copy(
            fromX: Int(position.readU16BE(at: 0)),
            fromY: Int(position.readU16BE(at: 2)),
            toX: header.x, toY: header.y,
            width: header.width, height: header.height
        )
    }

    // MARK: - RRE (encoding 2)

    static func rre(_ header: VNCWire.RectangleHeader, from source: VNCByteChannel, context: Context) throws {
        let count = Int(try source.read(exactly: 4).readU32BE(at: 0))
        let background = try readFullPixel(from: source, using: context)
        context.framebuffer.fill(x: header.x, y: header.y, width: header.width, height: header.height, pixel: background)
        for _ in 0 ..< count {
            let pixel = try readFullPixel(from: source, using: context)
            let subrect = try source.read(exactly: 8)
            context.framebuffer.fill(
                x: header.x + Int(subrect.readU16BE(at: 0)),
                y: header.y + Int(subrect.readU16BE(at: 2)),
                width: Int(subrect.readU16BE(at: 4)),
                height: Int(subrect.readU16BE(at: 6)),
                pixel: pixel
            )
        }
    }

    // MARK: - Hextile (encoding 5)

    private enum HextileSubencoding {
        static let raw: UInt8 = 1
        static let backgroundSpecified: UInt8 = 2
        static let foregroundSpecified: UInt8 = 4
        static let anySubrects: UInt8 = 8
        static let subrectsColoured: UInt8 = 16
    }

    static func hextile(_ header: VNCWire.RectangleHeader, from source: VNCByteChannel, context: Context) throws {
        var background: UInt32?
        var foreground: UInt32 = 0
        var tileY = header.y
        while tileY < header.y + header.height {
            var tileX = header.x
            let tileHeight = min(16, header.y + header.height - tileY)
            while tileX < header.x + header.width {
                let tileWidth = min(16, header.x + header.width - tileX)
                let subencoding = try source.read(exactly: 1)[0]

                if subencoding & HextileSubencoding.raw != 0 {
                    var line: [UInt32] = []
                    line.reserveCapacity(tileWidth * tileHeight)
                    let data = try source.read(exactly: tileWidth * tileHeight * context.bytesPerPixel)
                    for index in stride(from: 0, to: data.count, by: context.bytesPerPixel) {
                        line.append(context.pixelTranslator(data, index))
                    }
                    context.framebuffer.putRun(x: tileX, y: tileY, width: tileWidth, pixels: line[...])
                    tileX += tileWidth
                    continue
                }

                if subencoding & HextileSubencoding.backgroundSpecified != 0 {
                    background = try readFullPixel(from: source, using: context)
                }
                guard let background else {
                    throw VNCDecodeError.malformed("Hextile tile with no background specified")
                }
                context.framebuffer.fill(x: tileX, y: tileY, width: tileWidth, height: tileHeight, pixel: background)

                if subencoding & HextileSubencoding.foregroundSpecified != 0 {
                    foreground = try readFullPixel(from: source, using: context)
                }
                if subencoding & HextileSubencoding.anySubrects != 0 {
                    let count = Int(try source.read(exactly: 1)[0])
                    for _ in 0 ..< count {
                        var pixel = foreground
                        if subencoding & HextileSubencoding.subrectsColoured != 0 {
                            pixel = try readFullPixel(from: source, using: context)
                        }
                        let position = try source.read(exactly: 1)[0]
                        let dimension = try source.read(exactly: 1)[0]
                        context.framebuffer.fill(
                            x: tileX + Int(position >> 4),
                            y: tileY + Int(position & 0x0F),
                            width: Int(dimension >> 4) + 1,
                            height: Int(dimension & 0x0F) + 1,
                            pixel: pixel
                        )
                    }
                }
                tileX += tileWidth
            }
            tileY += tileHeight
        }
    }

    // MARK: - ZRLE (encoding 16)

    static func zrle(_ header: VNCWire.RectangleHeader, from source: VNCByteChannel, context: Context) throws {
        // u32 compressed length, then the zlib payload; the persistent
        // inflate stream lives on the client, handed in through `zlib`.
        guard let zlib = context.zlib else {
            throw VNCDecodeError.malformed("ZRLE without an inflate stream")
        }
        let length = Int(try source.read(exactly: 4).readU32BE(at: 0))
        guard length > 0, length <= 8 * 1024 * 1024 else {
            throw VNCDecodeError.malformed("ZRLE payload length \(length)")
        }
        let compressed = try source.read(exactly: length)
        let inflated = try zlib.inflate(compressed)
        try decodeZRLE(header, inflated: inflated, context: context)
    }

    /// Decodes one ZRLE rectangle. `data` is the already-inflated payload —
    /// the persistent zlib stream lives on the client — so this stays a
    /// pure buffer decode.
    static func decodeZRLE(_ header: VNCWire.RectangleHeader, inflated data: Data, context: Context) throws {
        var offset = 0

        func take(_ count: Int) throws -> [UInt8] {
            guard offset + count <= data.count else {
                throw VNCDecodeError.malformed("ZRLE payload ended early at \(offset) of \(data.count)")
            }
            defer { offset += count }
            return Array(data[offset ..< offset + count])
        }

        func cpixel() throws -> UInt32 {
            // CPIXEL drops the padding byte of a 32bpp/depth-24 pixel: the
            // trailing byte for little-endian wire order, the leading one
            // for big-endian.
            var bytes = try take(context.cpixelByteCount)
            while bytes.count < context.bytesPerPixel {
                if context.cpixelPadsAtEnd { bytes.append(0) } else { bytes.insert(0, at: 0) }
            }
            return context.pixelTranslator(Data(bytes), 0)
        }

        func palette(_ count: Int) throws -> [UInt32] {
            try (0 ..< count).map { _ in try cpixel() }
        }

        func runLength() throws -> Int {
            // "The length is encoded as a sequence of bytes; the run
            // continues while a byte is 255, total = sum + 1."
            var length = 1
            var next = try take(1)[0]
            length += Int(next)
            while next == 255 {
                next = try take(1)[0]
                length += Int(next)
            }
            return length
        }

        var tileY = 0
        while tileY < header.height {
            var tileX = 0
            let tileHeight = min(64, header.height - tileY)
            while tileX < header.width {
                let tileWidth = min(64, header.width - tileX)
                let subencoding = Int(try take(1)[0])

                if subencoding == 0 {
                    // Raw CPIXELs.
                    var line: [UInt32] = []
                    line.reserveCapacity(tileWidth * tileHeight)
                    for _ in 0 ..< tileWidth * tileHeight { line.append(try cpixel()) }
                    context.framebuffer.putRun(
                        x: header.x + tileX, y: header.y + tileY,
                        width: tileWidth, pixels: line[...]
                    )
                } else if subencoding == 1 {
                    // Solid fill.
                    let pixel = try cpixel()
                    context.framebuffer.fill(
                        x: header.x + tileX, y: header.y + tileY,
                        width: tileWidth, height: tileHeight, pixel: pixel
                    )
                } else if subencoding >= 2, subencoding <= 16 {
                    // Packed palette: 1-bit indices for 2 colours, 4-bit for
                    // 3–4, 8-bit otherwise.
                    let entries = try palette(subencoding)
                    let bitsPerIndex: Int = subencoding > 4 ? 8 : (subencoding > 2 ? 4 : 1)
                    let bytesPerRow = (tileWidth * bitsPerIndex + 7) / 8
                    for row in 0 ..< tileHeight {
                        let rowData = try take(bytesPerRow)
                        for column in 0 ..< tileWidth {
                            let bitIndex = column * bitsPerIndex
                            let byte = Int(rowData[bitIndex / 8])
                            let shift = 8 - bitsPerIndex - (bitIndex % 8)
                            let paletteIndex = (byte >> shift) & ((1 << bitsPerIndex) - 1)
                            guard paletteIndex < entries.count else {
                                throw VNCDecodeError.malformed("ZRLE palette index \(paletteIndex) out of \(entries.count)")
                            }
                            context.framebuffer.put(
                                x: header.x + tileX + column,
                                y: header.y + tileY + row,
                                pixel: entries[paletteIndex]
                            )
                        }
                    }
                } else if subencoding == 128 {
                    // Plain RLE: (CPIXEL, runLength) pairs.
                    var line: [UInt32] = []
                    let total = tileWidth * tileHeight
                    line.reserveCapacity(total)
                    var pixelsWritten = 0
                    while pixelsWritten < total {
                        let pixel = try cpixel()
                        let length = try runLength()
                        line.append(contentsOf: repeatElement(pixel, count: length))
                        pixelsWritten += length
                    }
                    context.framebuffer.putRun(
                        x: header.x + tileX, y: header.y + tileY,
                        width: tileWidth, pixels: line.prefix(total)
                    )
                } else {
                    // Palette RLE: palette size = subencoding & 0x7F; an
                    // index byte per element, bit 7 marking a run of that
                    // palette entry whose length follows.
                    let entries = try palette(subencoding & 0x7F)
                    var line: [UInt32] = []
                    let total = tileWidth * tileHeight
                    line.reserveCapacity(total)
                    var pixelsWritten = 0
                    while pixelsWritten < total {
                        let indicator = try take(1)[0]
                        let index = Int(indicator & 0x7F)
                        guard index < entries.count else {
                            throw VNCDecodeError.malformed("ZRLE palette index \(index) out of \(entries.count)")
                        }
                        var length = 1
                        if indicator & 0x80 != 0 {
                            length = try runLength()
                        }
                        line.append(contentsOf: repeatElement(entries[index], count: length))
                        pixelsWritten += length
                    }
                    context.framebuffer.putRun(
                        x: header.x + tileX, y: header.y + tileY,
                        width: tileWidth, pixels: line.prefix(total)
                    )
                }
                tileX += tileWidth
            }
            tileY += tileHeight
        }
    }

    // MARK: - Cursor pseudo-encoding (-239)

    /// Decodes the cursor shape inside its rectangle (x, y = hotspot).
    static func decodeCursor(_ header: VNCWire.RectangleHeader, from source: VNCByteChannel, context: Context) throws -> RemoteCursorInfo? {
        let pixelCount = header.width * header.height
        guard pixelCount > 0 else { return nil }
        let pixelData = try source.read(exactly: pixelCount * context.bytesPerPixel)
        let maskRowBytes = (header.width + 7) / 8
        let mask = try source.read(exactly: maskRowBytes * header.height)

        // RGBA with alpha from the mask: [R, G, B, A] bytes per pixel.
        var rgba = Data(count: pixelCount * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for index in 0 ..< pixelCount {
                let pixel = context.pixelTranslator(pixelData, index * context.bytesPerPixel)
                let row = index / header.width, column = index % header.width
                let maskByte = mask[mask.startIndex + row * maskRowBytes + column / 8]
                let visible = (maskByte >> (7 - column % 8)) & 1 == 1
                let pointer = base + index * 4
                pointer[0] = UInt8((pixel >> 16) & 0xFF)
                pointer[1] = UInt8((pixel >> 8) & 0xFF)
                pointer[2] = UInt8(pixel & 0xFF)
                pointer[3] = visible ? 0xFF : 0
            }
        }
        let image = CGImage(
            width: header.width,
            height: header.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: header.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big),
            provider: CGDataProvider(data: rgba as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
        return RemoteCursorInfo(
            x: Double(header.x), y: Double(header.y),
            width: header.width, height: header.height,
            image: image, visible: true
        )
    }
}
