//
//  VNCRFBTests.swift
//  CatusshModuleTests
//
//  Covers the RFB wire codec and the VNC-specific machine settings:
//  attachment persistence, DES challenge, message encoding, rectangle
//  decoders (Raw / CopyRect / RRE / Hextile / ZRLE), and key mapping.
//

@testable import CatusshModule
import CoreGraphics
import CryptoKit
import XCTest
import zlib

/// A byte channel that replays a fixed buffer — the decoders read through
/// the same `VNCByteChannel` API as the socket.
private final class MemoryChannel: VNCByteChannel, @unchecked Sendable {
    var buffer: [UInt8]
    var written: [UInt8] = []

    init(_ buffer: [UInt8] = []) { self.buffer = buffer }

    func read(exactly count: Int) throws -> Data {
        guard buffer.count >= count else { throw VNCStreamError.endOfStream }
        defer { buffer.removeFirst(count) }
        return Data(buffer.prefix(count))
    }

    func write(_ data: Data) throws {
        written.append(contentsOf: data)
    }

    func close() {}
}

private func makeContext(framebuffer: VNCFramebuffer, format: VNCPixelFormat = .clientRequested) -> VNCDecoders.Context {
    VNCDecoders.Context(
        framebuffer: framebuffer,
        pixelTranslator: format.translator()!,
        bytesPerPixel: format.bytesPerPixel,
        cpixelByteCount: format.cpixelByteCount,
        zlib: nil
    )
}

private func rectHeader(x: Int, y: Int, w: Int, h: Int, encoding: Int32) -> VNCWire.RectangleHeader {
    var data = Data()
    data.appendU16BE(UInt16(x))
    data.appendU16BE(UInt16(y))
    data.appendU16BE(UInt16(w))
    data.appendU16BE(UInt16(h))
    data.appendI32BE(encoding)
    return VNCWire.RectangleHeader(wire: data)!
}

final class VNCRFBTests: XCTestCase {
    // MARK: Machine configuration

    func testRemoteDesktopDefaults() {
        let machine = RDMachine()
        XCTAssertEqual(machine.remoteDesktopProtocol, .none)
        XCTAssertFalse(machine.hasRemoteDesktop)
        XCTAssertEqual(machine.vncPort, "5900")
        XCTAssertEqual(machine.vncPassword, "")
        XCTAssertTrue(machine.vncShared)
        XCTAssertFalse(machine.vncOverSSH)
        XCTAssertEqual(machine.uuDeviceID, "")
        XCTAssertEqual(machine.uuDisplayID, 0)
        XCTAssertEqual(machine.uuFPS, 60)
        XCTAssertEqual(machine.uuQuality, 5)
    }

    func testRemoteDesktopAttachmentRoundTrip() {
        var machine = RDMachine()
        machine.remoteDesktopProtocol = .vnc
        machine.vncPort = "5901"
        machine.vncPassword = "secret"
        machine.vncShared = false
        machine.vncOverSSH = true
        machine.uuDeviceID = "dev123"
        machine.uuAssistID = "assist"
        machine.uuDisplayID = 2
        machine.uuFPS = 144
        machine.uuQuality = 3

        XCTAssertEqual(machine.remoteDesktopProtocol, .vnc)
        XCTAssertTrue(machine.hasRemoteDesktop)
        XCTAssertEqual(machine.vncPort, "5901")
        XCTAssertEqual(machine.vncPassword, "secret")
        XCTAssertFalse(machine.vncShared)
        XCTAssertTrue(machine.vncOverSSH)
        XCTAssertEqual(machine.uuDeviceID, "dev123")
        XCTAssertEqual(machine.uuAssistID, "assist")
        XCTAssertEqual(machine.uuDisplayID, 2)
        XCTAssertEqual(machine.uuFPS, 144)
        XCTAssertEqual(machine.uuQuality, 3)
    }

    func testRemoteDesktopDefaultsAreNotWritten() {
        var machine = RDMachine()
        machine.remoteDesktopProtocol = .vnc
        XCTAssertEqual(machine.attachment["remoteDesktop.vnc.port"], nil)
        machine.vncPort = "6000"
        XCTAssertEqual(machine.attachment["remoteDesktop.vnc.port"], "6000")
        machine.vncPort = "5900"
        XCTAssertNil(machine.attachment["remoteDesktop.vnc.port"])
    }

    func testVNCPasswordFallsBackToIdentity() {
        var machine = RDMachine()
        let identity = RDIdentity(username: "u", password: "identity-password")
        XCTAssertEqual(machine.resolvedVNCPassword(identity: identity), "identity-password")
        machine.vncPassword = "explicit"
        XCTAssertEqual(machine.resolvedVNCPassword(identity: identity), "explicit")
    }

    // MARK: DES challenge

    func testDESBitReversal() {
        XCTAssertEqual(VNCDES.reverseBits(of: 0x01), 0x80)
        XCTAssertEqual(VNCDES.reverseBits(of: 0x02), 0x40)
        XCTAssertEqual(VNCDES.reverseBits(of: 0x80), 0x01)
        XCTAssertEqual(VNCDES.reverseBits(of: 0x70), 0x0E)
        XCTAssertEqual(VNCDES.reverseBits(of: 0x61), 0x86)
        XCTAssertEqual(VNCDES.reverseBits(of: 0xFF), 0xFF)
        XCTAssertEqual(VNCDES.reverseBits(of: 0x00), 0x00)
    }

    func testDESKeyIsBitReversedAndPadded() {
        let key = VNCDES.key(for: "password")
        // "password" -> 70 61 73 73 77 6f 72 64 -> 0e 86 ce ce ee f6 4e 26
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), "0e86ceceeef64e26")

        let short = VNCDES.key(for: "abc")
        // "abc\0\0\0\0\0" -> 61 62 63 00 00 00 00 00 -> 86 46 c6 00 00 00 00 00
        XCTAssertEqual(short.map { String(format: "%02x", $0) }.joined(), "8646c60000000000")
    }

    func testDESChallengeEncryption() {
        let challenge: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                                  0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]
        let response = VNCDES.encryptChallenge(challenge, password: "password")
        XCTAssertEqual(response?.map { String(format: "%02x", $0) }.joined(),
                       "abd26395c6fb36af4213133396e381c4")

        let challenge2: [UInt8] = [0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA, 0x99, 0x88,
                                   0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80]
        let response2 = VNCDES.encryptChallenge(challenge2, password: "abc")
        XCTAssertEqual(response2?.map { String(format: "%02x", $0) }.joined(),
                       "1644884249e9149e4ba3670d24c0eb10")
    }

    // MARK: Wire messages

    func testBannerRoundTrip() {
        let banner = VNCWire.banner(major: 3, minor: 8)
        XCTAssertEqual(String(data: banner, encoding: .ascii), "RFB 003.008\n")
        let parsed = VNCWire.parseBanner(banner)
        XCTAssertEqual(parsed?.major, 3)
        XCTAssertEqual(parsed?.minor, 8)
        XCTAssertNil(VNCWire.parseBanner(Data("not a banner!".utf8)))
    }

    func testClientMessageEncoding() {
        XCTAssertEqual(VNCWire.clientInit(shared: true), Data([1]))
        XCTAssertEqual(VNCWire.clientInit(shared: false), Data([0]))

        let update = VNCWire.framebufferUpdateRequest(incremental: true, x: 1, y: 2, width: 640, height: 480)
        XCTAssertEqual(update, Data([3, 1, 0, 1, 0, 2, 0x02, 0x80, 0x01, 0xE0]))

        let key = VNCWire.keyEvent(down: true, keySym: 0xFF0D)
        XCTAssertEqual(key, Data([4, 1, 0, 0, 0, 0, 0xFF, 0x0D]))

        let pointer = VNCWire.pointerEvent(buttonMask: 0b101, x: 100, y: 50)
        XCTAssertEqual(pointer, Data([5, 0b101, 0, 100, 0, 50]))

        let cut = VNCWire.clientCutText("hi")
        XCTAssertEqual(Array(cut.prefix(8)), [6, 0, 0, 0, 0, 0, 0, 2])
        XCTAssertEqual(Array(cut.suffix(2)), [0x68, 0x69])
    }

    func testCutTextLatin1() {
        XCTAssertEqual("héllo".latin1Bytes, [0x68, 0xE9, 0x6C, 0x6C, 0x6F])
        XCTAssertEqual("中".latin1Bytes, [UInt8(ascii: "?")])
    }

    func testSetPixelFormatEncoding() {
        let data = VNCWire.setPixelFormat(.clientRequested)
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(data[0], 0) // message type
        // Our requested format starts at byte 4.
        XCTAssertEqual(data[4], 32) // bits-per-pixel
        XCTAssertEqual(data[5], 24) // depth
        XCTAssertEqual(data[6], 0) // little-endian
        XCTAssertEqual(data[7], 1) // true colour
        XCTAssertEqual(data.readU16BE(at: 8), 255)
        XCTAssertEqual(data[14], 16) // red shift
        XCTAssertEqual(data[15], 8) // green shift
        XCTAssertEqual(data[16], 0) // blue shift
    }

    func testSetEncodingsEncoding() {
        let data = VNCWire.setEncodings([0, 1, -223])
        XCTAssertEqual(data[0], 2)
        XCTAssertEqual(data.readU16BE(at: 2), 3)
        XCTAssertEqual(data.readI32BE(at: 4), 0)
        XCTAssertEqual(data.readI32BE(at: 8), 1)
        XCTAssertEqual(data.readI32BE(at: 12), -223)
    }

    func testServerInitParsing() {
        var data = Data()
        data.appendU16BE(1024)
        data.appendU16BE(768)
        data.append(VNCPixelFormat.clientRequested.wire)
        data.appendU32BE(3)
        data.append(contentsOf: "mac".utf8)
        let init_ = VNCWire.parseServerInit(data: data)
        XCTAssertEqual(init_?.width, 1024)
        XCTAssertEqual(init_?.height, 768)
        XCTAssertEqual(init_?.desktopName, "mac")
        XCTAssertEqual(init_?.pixelFormat, .clientRequested)
    }

    // MARK: Pixel format translation

    func testPixelTranslator32bpp() {
        let translator = VNCPixelFormat.clientRequested.translator()!
        // BGRX bytes: B=0x11, G=0x22, R=0x33, X=0xFF.
        let pixel = translator(Data([0x11, 0x22, 0x33, 0xFF]), 0)
        XCTAssertEqual(pixel, 0xFF_33_22_11)
    }

    func testPixelTranslatorRGB565() {
        let format = VNCPixelFormat(
            bitsPerPixel: 16, depth: 16, bigEndian: false, trueColour: true,
            redMax: 31, greenMax: 63, blueMax: 31,
            redShift: 11, greenShift: 5, blueShift: 0
        )
        let translator = format.translator()!
        // Full red: raw = 31 << 11 = 0xF800 -> LE bytes 00 F8.
        let red = translator(Data([0x00, 0xF8]), 0)
        XCTAssertEqual(red, 0xFF_FF_00_00)
        // Full green: raw = 63 << 5 = 0x07E0.
        let green = translator(Data([0xE0, 0x07]), 0)
        XCTAssertEqual(green, 0xFF_00_FF_00)
    }

    func testPixelTranslatorBigEndian() {
        let format = VNCPixelFormat(
            bitsPerPixel: 32, depth: 24, bigEndian: true, trueColour: true,
            redMax: 255, greenMax: 255, blueMax: 255,
            redShift: 16, greenShift: 8, blueShift: 0
        )
        let translator = format.translator()!
        // BE raw: 00 33 22 11 -> R=0x33, G=0x22, B=0x11.
        let pixel = translator(Data([0x00, 0x33, 0x22, 0x11]), 0)
        XCTAssertEqual(pixel, 0xFF_33_22_11)
    }

    // MARK: Rectangle decoders

    func testRawDecode() throws {
        let framebuffer = VNCFramebuffer()
        framebuffer.resize(width: 4, height: 4)
        let context = makeContext(framebuffer: framebuffer)
        // 2x2 raw rect at (1,1): pixels R,G,B,W in BGRX byte order.
        let pixels: [UInt8] = [
            0x00, 0x00, 0xFF, 0, // blue 0xFFFF0000 -> R=255
            0x00, 0xFF, 0x00, 0, // green
            0xFF, 0x00, 0x00, 0, // red channel of B byte=0xFF -> B=255
            0xFF, 0xFF, 0xFF, 0, // white
        ]
        let channel = MemoryChannel(pixels)
        let header = rectHeader(x: 1, y: 1, w: 2, h: 2, encoding: 0)
        try VNCDecoders.raw(header, from: channel, context: context)

        XCTAssertEqual(framebuffer.pixel(x: 1, y: 1), 0xFF_FF_00_00)
        XCTAssertEqual(framebuffer.pixel(x: 2, y: 1), 0xFF_00_FF_00)
        XCTAssertEqual(framebuffer.pixel(x: 1, y: 2), 0xFF_00_00_FF)
        XCTAssertEqual(framebuffer.pixel(x: 2, y: 2), 0xFF_FF_FF_FF)
    }

    func testCopyRectDecode() throws {
        let framebuffer = VNCFramebuffer()
        framebuffer.resize(width: 8, height: 8)
        framebuffer.fill(x: 0, y: 0, width: 4, height: 4, pixel: 0xFF_AA_BB_CC)
        var payload = Data()
        payload.appendU16BE(0) // src x
        payload.appendU16BE(0) // src y
        let channel = MemoryChannel(Array(payload))
        try VNCDecoders.copyRect(rectHeader(x: 4, y: 4, w: 4, h: 4, encoding: 1), from: channel, context: makeContext(framebuffer: framebuffer))
        XCTAssertEqual(framebuffer.pixel(x: 7, y: 7), 0xFF_AA_BB_CC)
    }

    func testRREDecode() throws {
        let framebuffer = VNCFramebuffer()
        framebuffer.resize(width: 16, height: 16)
        let context = makeContext(framebuffer: framebuffer)

        var payload = Data()
        payload.appendU32BE(2) // two subrects
        // background = red (BGRX bytes B=0,G=0,R=255,X ignored)
        payload.append(contentsOf: [0, 0, 0xFF, 0])
        // subrect 1: green at (0,0) 4x4
        payload.append(contentsOf: [0, 0xFF, 0, 0])
        payload.appendU16BE(0); payload.appendU16BE(0); payload.appendU16BE(4); payload.appendU16BE(4)
        // subrect 2: blue at (8,8) 2x2
        payload.append(contentsOf: [0xFF, 0, 0, 0])
        payload.appendU16BE(8); payload.appendU16BE(8); payload.appendU16BE(2); payload.appendU16BE(2)

        let channel = MemoryChannel(Array(payload))
        try VNCDecoders.rre(rectHeader(x: 0, y: 0, w: 16, h: 16, encoding: 2), from: channel, context: context)

        XCTAssertEqual(framebuffer.pixel(x: 0, y: 0), 0xFF_00_FF_00)
        XCTAssertEqual(framebuffer.pixel(x: 8, y: 8), 0xFF_00_00_FF)
        XCTAssertEqual(framebuffer.pixel(x: 15, y: 15), 0xFF_FF_00_00)
        XCTAssertEqual(framebuffer.pixel(x: 4, y: 0), 0xFF_FF_00_00) // background outside subrects
    }

    func testHextileDecode() throws {
        let framebuffer = VNCFramebuffer()
        framebuffer.resize(width: 32, height: 32)
        let context = makeContext(framebuffer: framebuffer)

        var payload = Data()
        // Tile (0,0): backgroundSpecified + anySubrects + subrectsColoured
        // bg = white; one coloured subrect (red) at (2,3) size 5x4.
        payload.append(0x02 | 0x08 | 0x10)
        payload.append(contentsOf: [0xFF, 0xFF, 0xFF, 0]) // bg white
        payload.append(1) // one subrect
        payload.append(contentsOf: [0x00, 0x00, 0xFF, 0]) // red
        payload.append(0x23) // x=2, y=3
        payload.append(0x43) // w-1=4, h-1=3 -> 5x4
        // Tile (16,0): raw tile — 16x16 green.
        payload.append(0x01)
        for _ in 0 ..< 16 * 16 { payload.append(contentsOf: [0x00, 0xFF, 0x00, 0]) }
        // Tile (0,16): fill with previous bg? Per spec each new tile re-reads
        // bg when specified; tile 3 keeps the previous background (white)
        // with no new specification: subencoding = 0x04 (fg specified, fg=black)
        // + 0x08 anySubrects, one uncoloured subrect at (0,0) 3x3 black.
        payload.append(0x04 | 0x08)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0]) // fg black
        payload.append(1)
        payload.append(0x00) // x=0,y=0
        payload.append(0x22) // 3x3
        // Tile (16,16): all-white background fill, no subrects.
        payload.append(0x00)

        let channel = MemoryChannel(Array(payload))
        try VNCDecoders.hextile(rectHeader(x: 0, y: 0, w: 32, h: 32, encoding: 5), from: channel, context: context)

        // Tile (0,0): white bg + red subrect at (2,3)..(6,6).
        XCTAssertEqual(framebuffer.pixel(x: 0, y: 0), 0xFF_FF_FF_FF)
        XCTAssertEqual(framebuffer.pixel(x: 4, y: 5), 0xFF_FF_00_00)
        // Tile (16,0): raw green.
        XCTAssertEqual(framebuffer.pixel(x: 20, y: 5), 0xFF_00_FF_00)
        // Tile (0,16): white bg (carried over) + black subrect at (0,16)..(2,18).
        XCTAssertEqual(framebuffer.pixel(x: 0, y: 16), 0xFF_00_00_00)
        XCTAssertEqual(framebuffer.pixel(x: 5, y: 20), 0xFF_FF_FF_FF)
        // Tile (16,16): carried white fill.
        XCTAssertEqual(framebuffer.pixel(x: 20, y: 20), 0xFF_FF_FF_FF)
    }

    // MARK: ZRLE

    private func zlibCompress(_ data: Data) -> Data {
        var stream = z_stream()
        deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        defer { deflateEnd(&stream) }
        var output = Data()
        let capacity = 64 * 1024
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { chunk.deallocate() }
        data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: input.baseAddress!.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = uInt(input.count)
            repeat {
                stream.next_out = chunk
                stream.avail_out = uInt(capacity)
                deflate(&stream, Z_FINISH)
                let produced = capacity - Int(stream.avail_out)
                output.append(chunk, count: produced)
            } while stream.avail_out == 0
        }
        return output
    }

    private func inflate(_ compressed: Data) throws -> Data {
        let stream = VNCZlibStream()
        return try stream.inflate(compressed)
    }

    func testZlibRoundTrip() throws {
        let original = Data((0 ..< 1000).map { UInt8($0 % 251) })
        let inflated = try inflate(zlibCompress(original))
        XCTAssertEqual(inflated, original)
    }

    func testZRLESolidAndRawTiles() throws {
        let framebuffer = VNCFramebuffer()
        framebuffer.resize(width: 80, height: 8)
        let context = makeContext(framebuffer: framebuffer)

        // Tiles are at most 64 wide: an 80x8 rect is two tiles.
        // Tile (0,0) 64x8 solid red; tile (64,0) 16x8 raw green.
        // CPIXEL is 3 bytes (B,G,R) for our format.
        var payload = Data()
        payload.append(0x01) // solid
        payload.append(contentsOf: [0x00, 0x00, 0xFF]) // red cpixel
        payload.append(0x00) // raw
        for _ in 0 ..< 16 * 8 { payload.append(contentsOf: [0x00, 0xFF, 0x00]) }

        try VNCDecoders.decodeZRLE(rectHeader(x: 0, y: 0, w: 80, h: 8, encoding: 16),
                                   inflated: payload, context: context)

        XCTAssertEqual(framebuffer.pixel(x: 0, y: 0), 0xFF_FF_00_00)
        XCTAssertEqual(framebuffer.pixel(x: 63, y: 7), 0xFF_FF_00_00)
        XCTAssertEqual(framebuffer.pixel(x: 64, y: 0), 0xFF_00_FF_00)
        XCTAssertEqual(framebuffer.pixel(x: 79, y: 7), 0xFF_00_FF_00)
    }

    func testZRLEPackedPalette() throws {
        let framebuffer = VNCFramebuffer()
        framebuffer.resize(width: 8, height: 8)
        let context = makeContext(framebuffer: framebuffer)

        // 8x8 packed palette, 2 colours -> 1 bit per pixel: rows alternate
        // 0xAA (10101010) pattern of two colours.
        var payload = Data()
        payload.append(0x02) // packed palette, 2 entries
        payload.append(contentsOf: [0x00, 0x00, 0xFF]) // entry 0 = red
        payload.append(contentsOf: [0x00, 0xFF, 0x00]) // entry 1 = green
        for _ in 0 ..< 8 { payload.append(0xAA) }

        try VNCDecoders.decodeZRLE(rectHeader(x: 0, y: 0, w: 8, h: 8, encoding: 16),
                                   inflated: payload, context: context)

        XCTAssertEqual(framebuffer.pixel(x: 0, y: 0), 0xFF_00_FF_00) // bit 1 -> entry 1
        XCTAssertEqual(framebuffer.pixel(x: 1, y: 0), 0xFF_FF_00_00) // bit 0 -> entry 0
    }

    func testZRLEPlainRLE() throws {
        let framebuffer = VNCFramebuffer()
        framebuffer.resize(width: 4, height: 4)
        let context = makeContext(framebuffer: framebuffer)

        // Plain RLE tile 4x4 = 16 pixels: run of 12 red + 4 green.
        var payload = Data()
        payload.append(0x80) // plain RLE
        payload.append(contentsOf: [0x00, 0x00, 0xFF]) // red
        payload.append(11) // length-1 = 11 -> 12 pixels
        payload.append(contentsOf: [0x00, 0xFF, 0x00]) // green
        payload.append(3) // 4 pixels

        try VNCDecoders.decodeZRLE(rectHeader(x: 0, y: 0, w: 4, h: 4, encoding: 16),
                                   inflated: payload, context: context)

        XCTAssertEqual(framebuffer.pixel(x: 0, y: 0), 0xFF_FF_00_00)
        XCTAssertEqual(framebuffer.pixel(x: 3, y: 2), 0xFF_FF_00_00) // pixel 11
        XCTAssertEqual(framebuffer.pixel(x: 0, y: 3), 0xFF_00_FF_00) // pixel 12
    }

    // MARK: KeySyms

    func testKeySymsForCharacters() {
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "a"), 0x61)
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "Z"), 0x5A)
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "\n"), 0xFF0D)
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "\t"), 0xFF09)
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "\u{7F}"), 0xFF08) // DEL char -> BackSpace
        // Latin-1 supplement (U+00A0...U+00FF) maps to the identical
        // KeySym value per keysymdef.h, not the 0x01000000 convention.
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "é"), 0xE9)
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "\u{A0}"), 0xA0) // NBSP
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "ü"), 0xFC)
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "ÿ"), 0xFF)
        // Non-Latin-1 still uses the 0x01000000 | scalar convention.
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "中"), 0x0100_4E2D)
        XCTAssertEqual(VNCKeySyms.keySym(forCharacter: "Ā"), 0x0100_0100) // U+0100
    }

    func testKeySymsForKeyCodes() {
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 36, characters: "\r"), 0xFF0D) // Return
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 53, characters: ""), 0xFF1B) // Escape
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 123, characters: ""), 0xFF51) // Left
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 124, characters: ""), 0xFF53) // Right
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 126, characters: ""), 0xFF52) // Up
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 125, characters: ""), 0xFF54) // Down
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 122, characters: ""), 0xFFBE) // F1
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 55, characters: ""), 0xFFEB) // LCommand -> Super_L
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 58, characters: ""), 0xFFE9) // LOption -> Alt_L
        // Letter key falls back to its character.
        XCTAssertEqual(VNCKeySyms.keySym(forKeyCode: 0, characters: "a"), 0x61)
    }

    // MARK: Full handshake over a memory channel

    private final class RecordingDelegate: VNCRFBClientDelegate, @unchecked Sendable {
        var phases: [RemoteDesktopPhase] = []
        var size: CGSize = .zero
        var desktopName: String?
        var clipboards: [String] = []

        func client(_: VNCRFBClient, didChangePhase phase: RemoteDesktopPhase, hint _: String?) {
            phases.append(phase)
        }

        func client(_: VNCRFBClient, didUpdateFrame _: CGImage?, size: CGSize, desktopName: String?) {
            self.size = size
            if let desktopName { self.desktopName = desktopName }
        }

        func client(_: VNCRFBClient, didUpdateCursor _: RemoteCursorInfo?) {}

        func client(_: VNCRFBClient, didReceiveClipboard text: String) {
            clipboards.append(text)
        }
    }

    private func serverInitData(width: Int, height: Int, name: String) -> Data {
        var data = Data()
        data.appendU16BE(UInt16(width))
        data.appendU16BE(UInt16(height))
        data.append(VNCPixelFormat.clientRequested.wire)
        data.appendU32BE(UInt32(name.utf8.count))
        data.append(contentsOf: name.utf8)
        return data
    }

    func testHandshake38WithVncAuth() throws {
        // A scripted 3.8 server that asks for VNC auth and then delivers a
        // ServerInit plus one raw FramebufferUpdate and a cut text.
        var server = Data()
        server.append(VNCWire.banner(major: 3, minor: 8))
        server.append(1) // one security type
        server.append(VNCWire.SecurityType.vncAuth.rawValue)
        server.append(contentsOf: (0 ..< 16).map { UInt8($0) }) // challenge
        server.appendU32BE(0) // security result OK
        server.append(serverInitData(width: 4, height: 4, name: "vnc-host"))
        // FramebufferUpdate: one raw 2x2 rect at (0,0).
        server.append(0) // type
        server.append(0) // padding
        server.appendU16BE(1) // one rect
        server.appendU16BE(0); server.appendU16BE(0)
        server.appendU16BE(2); server.appendU16BE(2)
        server.appendI32BE(0) // Raw
        for _ in 0 ..< 4 { server.append(contentsOf: [0x00, 0x00, 0xFF, 0x00]) }
        // ServerCutText.
        server.append(3)
        server.append(contentsOf: [0, 0, 0])
        server.appendU32BE(5)
        server.append(contentsOf: "hello".utf8)

        let channel = MemoryChannel(Array(server))
        let delegate = RecordingDelegate()
        let client = VNCRFBClient(
            configuration: .init(host: "ignored", port: 0, password: "password", shared: true, channel: channel),
            delegate: delegate
        )
        // Synchronous run: the channel replays the script, then hits
        // end-of-stream and reports the connection closed.
        client.run()

        XCTAssertTrue(delegate.phases.contains(.connected))
        XCTAssertEqual(delegate.size, CGSize(width: 4, height: 4))
        XCTAssertEqual(delegate.desktopName, "vnc-host")
        XCTAssertEqual(delegate.clipboards, ["hello"])
        XCTAssertTrue(delegate.phases.contains { phase in
            if case .closed = phase { return true }
            return false
        })
        // The client wrote: version banner (12), security-type selection
        // (1), DES response (16), ClientInit (1), SetPixelFormat (20),
        // SetEncodings (4 + 7x4), and two FramebufferUpdateRequests (10+10).
        XCTAssertEqual(channel.written.count, 12 + 1 + 16 + 1 + 20 + (4 + 7 * 4) + 10 + 10)
    }

    func testHandshakeServerRejectsPassword() throws {
        var server = Data()
        server.append(VNCWire.banner(major: 3, minor: 8))
        server.append(1)
        server.append(VNCWire.SecurityType.vncAuth.rawValue)
        server.append(contentsOf: (0 ..< 16).map { UInt8($0) })
        server.appendU32BE(1) // security result: failed
        server.appendU32BE(12)
        server.append(contentsOf: "bad password".utf8)

        let delegate = RecordingDelegate()
        let client = VNCRFBClient(
            configuration: .init(host: "ignored", port: 0, password: "wrong", shared: true,
                                 channel: MemoryChannel(Array(server))),
            delegate: delegate
        )
        client.run()
        XCTAssertTrue(delegate.phases.contains { phase in
            if case let .failed(reason) = phase { return reason.contains("bad password") }
            return false
        })
    }

    func testHandshakeNoSupportedSecurity() throws {
        var server = Data()
        server.append(VNCWire.banner(major: 3, minor: 8))
        server.append(1)
        server.append(30) // only Apple Remote Desktop auth
        let delegate = RecordingDelegate()
        let client = VNCRFBClient(
            configuration: .init(host: "ignored", port: 0, password: "", shared: true,
                                 channel: MemoryChannel(Array(server))),
            delegate: delegate
        )
        client.run()
        XCTAssertTrue(delegate.phases.contains { phase in
            if case .failed = phase { return true }
            return false
        })
    }

    // MARK: Apple Remote Desktop authentication (type 30)

    func testBigNumModularPowerSmall() {
        let result = VNCBigNum(4).power(VNCBigNum(13), modulo: VNCBigNum(497))
        XCTAssertEqual(result, VNCBigNum(445))
    }

    func testBigNumModularPowerMatchesUInt64() {
        // The largest 64-bit prime: two limbs, checked against full-width math.
        let modulus: UInt64 = 0xFFFF_FFFF_FFFF_FFC5
        func mulmod(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let product = a.multipliedFullWidth(by: b)
            return modulus.dividingFullWidth((product.high, product.low)).remainder
        }
        var expected: UInt64 = 1
        var base: UInt64 = 0x1234_5678_9ABC_DEF0 % modulus
        var exponent: UInt64 = 1_000_003
        while exponent > 0 {
            if exponent & 1 == 1 { expected = mulmod(expected, base) }
            base = mulmod(base, base)
            exponent >>= 1
        }
        let result = VNCBigNum(0x1234_5678_9ABC_DEF0).power(VNCBigNum(1_000_003), modulo: VNCBigNum(modulus))
        XCTAssertEqual(result, VNCBigNum(expected))
    }

    func testBigNumBytesRoundTrip() {
        let bytes: [UInt8] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
        XCTAssertEqual(VNCBigNum(bigEndian: bytes).bigEndianBytes(length: 7), bytes)
        XCTAssertEqual(VNCBigNum(bigEndian: [0x01, 0x00]).bigEndianBytes(length: 4), [0, 0, 1, 0])
    }

    /// RFC 2409's 1024-bit MODP group, the size macOS uses.
    private static let oakleyPrime: [UInt8] = {
        let hex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF"
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        return bytes
    }()

    func testDiffieHellmanAgrees() {
        let prime = VNCBigNum(bigEndian: Self.oakleyPrime)
        let a = VNCBigNum(bigEndian: VNCAppleAuth.randomBytes(32))
        let b = VNCBigNum(bigEndian: VNCAppleAuth.randomBytes(32))
        let g = VNCBigNum(2)
        let left = g.power(a, modulo: prime).power(b, modulo: prime)
        let right = g.power(b, modulo: prime).power(a, modulo: prime)
        XCTAssertEqual(left, right)
        XCTAssertFalse(left.isZero)
    }

    func testHandshake38WithAppleRemoteDesktopAuth() throws {
        let prime = VNCBigNum(bigEndian: Self.oakleyPrime)
        let serverSecret = VNCBigNum(bigEndian: VNCAppleAuth.randomBytes(128))
        let serverPublic = VNCBigNum(2).power(serverSecret, modulo: prime)

        var server = Data()
        server.append(VNCWire.banner(major: 3, minor: 889)) // macOS's banner
        server.append(2)
        server.append(contentsOf: [VNCWire.SecurityType.vncAuth.rawValue, VNCWire.SecurityType.appleRemoteDesktop.rawValue])
        server.appendU16BE(2) // generator
        server.appendU16BE(128) // key length
        server.append(contentsOf: Self.oakleyPrime)
        server.append(contentsOf: serverPublic.bigEndianBytes(length: 128))
        server.appendU32BE(0) // security result OK
        server.append(serverInitData(width: 2, height: 2, name: "mac"))

        let channel = MemoryChannel(Array(server))
        let delegate = RecordingDelegate()
        let client = VNCRFBClient(
            configuration: .init(host: "ignored", port: 0, password: "secret", username: "alice", shared: true, channel: channel),
            delegate: delegate
        )
        client.run()
        XCTAssertTrue(delegate.phases.contains(.connected))
        XCTAssertEqual(delegate.desktopName, "mac")

        // banner(12), selection(1) = type 30, credentials(128), public key(128).
        let written = channel.written
        XCTAssertEqual(written[12], VNCWire.SecurityType.appleRemoteDesktop.rawValue)
        let cipher = Array(written[13 ..< 141])
        let clientPublic = VNCBigNum(bigEndian: Array(written[141 ..< 269]))
        let shared = clientPublic.power(serverSecret, modulo: prime)
        let key = Array(Insecure.MD5.hash(data: Data(shared.bigEndianBytes(length: 128))))
        let plain = try XCTUnwrap(VNCAppleAuth.aes128ECB(cipher, key: key, decrypt: true))
        XCTAssertEqual(Array(plain[0 ..< 6]), Array("alice".utf8) + [0])
        XCTAssertEqual(Array(plain[64 ..< 71]), Array("secret".utf8) + [0])
    }

    func testAppleAuthPrefersVNCPasswordWithoutUser() throws {
        var server = Data()
        server.append(VNCWire.banner(major: 3, minor: 8))
        server.append(2)
        server.append(contentsOf: [VNCWire.SecurityType.appleRemoteDesktop.rawValue, VNCWire.SecurityType.vncAuth.rawValue])
        let channel = MemoryChannel(Array(server))
        let client = VNCRFBClient(
            configuration: .init(host: "ignored", port: 0, password: "pw", shared: true, channel: channel),
            delegate: RecordingDelegate()
        )
        client.run()
        XCTAssertEqual(channel.written[12], VNCWire.SecurityType.vncAuth.rawValue)
    }

    func testVNCUsernameFallsBackOnlyWithIdentityPassword() {
        let identity = RDIdentity(username: "alice", password: "login")
        var machine = RDMachine()
        XCTAssertEqual(machine.resolvedVNCUsername(identity: identity), "alice")
        // A stored VNC password is not the identity's: VNC auth, no user.
        machine.vncPassword = "vnc-only"
        XCTAssertEqual(machine.resolvedVNCUsername(identity: identity), "")
        machine.vncUsername = "bob"
        XCTAssertEqual(machine.resolvedVNCUsername(identity: identity), "bob")
    }
}
