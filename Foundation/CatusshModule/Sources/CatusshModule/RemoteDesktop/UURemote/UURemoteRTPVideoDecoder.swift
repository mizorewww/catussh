//
//  UURemoteRTPVideoDecoder.swift
//  CatusshModule
//
//  RTP/H.264/H.265 depacketization to Annex-B access units, parameter-set
//  extraction, and VideoToolbox decompression to CGImage frames. Mirrors
//  the official Mac server's VideoStreamerDisplay / RTCVideoFrameDecoder and
//  /tmp/uu-refs/openuuyc/src/transport/rtc channels/negotiation.
//

import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

public enum UURTPError: Error, Sendable {
    case malformedPacket
    case unsupportedCodec(String)
    case missingParameterSet
    case decompressionFailed(OSStatus)
}

public struct UURTPPacket: Sendable {
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32
    public var marker: Bool
    public var payloadType: UInt8
    public var codecName: String
    public var payload: Data
}

/// One complete decoded video frame in Annex-B format.
public struct UUVideoAccessUnit: Sendable {
    public var nalUnits: [Data]
    public var sequence: UInt16
    public var timestamp: UInt32
    public var codecName: String
}

/// Aggregates RTP packets by sequence/timestamp into complete access units,
/// reassembling H.264 FU-A (RFC 6184) and HEVC FU (RFC 7798) fragments.
/// Mirrors the `Receiver` in /tmp/uu-refs/uu-remote-linux/src/viewer/media.rs.
public final class UURTPVideoAssembler: @unchecked Sendable {
    private struct Slot {
        var packets: [UInt16: UURTPPacket] = [:]
        var timestamp: UInt32 = 0
        var sequenceStart: UInt16 = 0
        var sequenceEnd: UInt16 = 0
        var haveStart = false
        var complete = false
        var codecName = "H264"
    }

    private var slots: [UInt32: Slot] = [:]
    private var lastEmitTimestamp: UInt32 = 0
    private let reorderDepth = 8

    /// RTP payload types that carry H.265 — from the negotiated SDP
    /// (`a=rtpmap:<pt> H265/90000`). The upstream offer uses 104; 127 is a
    /// defensive extra seen in some builds.
    public var h265PayloadTypes: Set<UInt8> = [104, 127]

    public init() {}

    /// Parses one raw RTP datagram: fixed header + CSRCs, the header
    /// extension (X bit), and trailing padding (P bit) all stripped, like
    /// the library-level RTP parse upstream relies on.
    public static func parsePacket(_ data: Data) -> UURTPPacket? {
        guard data.count >= 12, (data[0] & 0xC0) == 0x80 else { return nil }
        let csrcCount = Int(data[0] & 0x0F)
        let hasPadding = (data[0] & 0x20) != 0
        let hasExtension = (data[0] & 0x10) != 0
        let marker = (data[1] & 0x80) != 0
        let payloadType = data[1] & 0x7F
        let sequence = UInt16(data[2]) << 8 | UInt16(data[3])
        let timestamp = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 | UInt32(data[6]) << 8 | UInt32(data[7])
        let ssrc = UInt32(data[8]) << 24 | UInt32(data[9]) << 16 | UInt32(data[10]) << 8 | UInt32(data[11])

        var offset = 12 + csrcCount * 4
        guard offset <= data.count else { return nil }
        if hasExtension {
            // 16-bit profile + 16-bit length in 32-bit words, then the body.
            guard offset + 4 <= data.count else { return nil }
            let extensionWords = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4 + extensionWords * 4
            guard offset <= data.count else { return nil }
        }
        var end = data.count
        if hasPadding {
            let padCount = Int(data[data.count - 1])
            end = max(offset, data.count - padCount)
        }
        guard end > offset else { return nil }
        let payload = Data(data[offset ..< end])
        return UURTPPacket(
            sequence: sequence,
            timestamp: timestamp,
            ssrc: ssrc,
            marker: marker,
            payloadType: payloadType,
            codecName: "H264",
            payload: payload
        )
    }

    /// Feeds one RTP packet. Returns a complete access unit when a marker
    /// packet finishes the frame's packet train.
    public func insert(_ packet: UURTPPacket) -> UUVideoAccessUnit? {
        let codecName = h265PayloadTypes.contains(packet.payloadType) ? "H265" : "H264"
        var slot = slots[packet.timestamp] ?? Slot(timestamp: packet.timestamp, codecName: codecName)
        slot.packets[packet.sequence] = packet
        if !slot.haveStart || Int16(bitPattern: packet.sequence) < Int16(bitPattern: slot.sequenceStart) {
            slot.sequenceStart = packet.sequence
            slot.haveStart = true
        }
        if packet.marker {
            slot.sequenceEnd = packet.sequence
            slot.complete = true
        }
        slots[packet.timestamp] = slot

        guard slot.complete else { return nil }
        let sequenceCount = Int(slot.sequenceEnd &- slot.sequenceStart &+ 1)
        guard sequenceCount > 0, slot.packets.count == sequenceCount else {
            slots.removeValue(forKey: packet.timestamp)
            return nil
        }

        var nalUnits: [Data] = []
        var fragment: Data?
        var sequence = slot.sequenceStart
        var damaged = false
        while true {
            guard let p = slot.packets[sequence],
                  process(p.payload, codec: slot.codecName, into: &nalUnits, fragment: &fragment)
            else { damaged = true; break }
            if sequence == slot.sequenceEnd { break }
            sequence = sequence &+ 1
        }
        if damaged || fragment != nil { nalUnits = [] }
        slots.removeValue(forKey: packet.timestamp)
        lastEmitTimestamp = packet.timestamp

        // Evict stale reassembly slots that never completed.
        let cutoff = packet.timestamp &- UInt32(reorderDepth * 3000)
        slots = slots.filter { $0.key > cutoff || $0.key == packet.timestamp }

        guard !nalUnits.isEmpty else { return nil }
        return UUVideoAccessUnit(nalUnits: nalUnits, sequence: slot.sequenceStart, timestamp: slot.timestamp, codecName: slot.codecName)
    }

    /// Processes one RTP payload into the NAL list of the access unit under
    /// reassembly; `fragment` carries an open FU-A/FU fragment between
    /// packets. Returns false when the packet is malformed for the codec.
    private func process(_ payload: Data, codec: String, into nalUnits: inout [Data], fragment: inout Data?) -> Bool {
        guard !payload.isEmpty else { return false }
        let isH265 = codec.uppercased().contains("H265") || codec.uppercased().contains("HEVC")
        return isH265
            ? processHEVC(payload, into: &nalUnits, fragment: &fragment)
            : processH264(payload, into: &nalUnits, fragment: &fragment)
    }

    /// Backward-compatible single-payload depacketizer (STAP-A / AP / FU
    /// start fragments only split or queue; complete units are returned).
    public func depacketize(_ payload: Data, codec: String) -> [Data]? {
        var nalUnits: [Data] = []
        var fragment: Data?
        guard process(payload, codec: codec, into: &nalUnits, fragment: &fragment) else { return nil }
        if let fragment, !fragment.isEmpty { nalUnits.append(fragment) }
        return nalUnits.isEmpty ? nil : nalUnits
    }

    // MARK: H.264 (RFC 6184)

    private func processH264(_ payload: Data, into nalUnits: inout [Data], fragment: inout Data?) -> Bool {
        let header = payload[0]
        guard header & 0x80 == 0 else { return false } // F bit must be clear
        switch header & 0x1F {
        case 1 ... 23:
            guard fragment == nil else { return false }
            nalUnits.append(payload)
            return true
        case 24: // STAP-A
            guard fragment == nil else { return false }
            return depacketizeSTAPA(payload, into: &nalUnits)
        case 28: // FU-A
            guard payload.count > 2 else { return false }
            let fu = payload[1]
            let kind = fu & 0x1F
            let isStart = (fu & 0x80) != 0
            let isEnd = (fu & 0x40) != 0
            // R must be clear; kind must be a valid single NAL; S and E
            // are mutually exclusive.
            guard fu & 0x20 == 0, kind >= 1, kind <= 23, !(isStart && isEnd) else { return false }
            let nalHeader = (header & 0xE0) | kind
            if isStart {
                guard fragment == nil else { return false }
                var head = Data([nalHeader])
                head.append(payload[2...])
                fragment = head
                return true
            }
            guard var open = fragment, open.first == nalHeader else { return false }
            open.append(payload[2...])
            fragment = isEnd ? nil : open
            if isEnd { nalUnits.append(open) }
            return true
        default:
            return false
        }
    }

    private func depacketizeSTAPA(_ payload: Data, into nalUnits: inout [Data]) -> Bool {
        guard payload.count > 1 else { return false }
        var offset = 1
        while offset + 2 <= payload.count {
            let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            offset += 2
            guard size > 0, offset + size <= payload.count else { return false }
            let nal = payload[offset ..< offset + size]
            guard let first = nal.first, first & 0x80 == 0, (1 ... 23).contains(first & 0x1F) else { return false }
            nalUnits.append(Data(nal))
            offset += size
        }
        return !nalUnits.isEmpty
    }

    // MARK: HEVC (RFC 7798)

    /// Validates the 2-byte HEVC NAL header: F bit clear, nonzero TID.
    private static func validHEVCHeader(_ bytes: Data.SubSequence) -> Bool {
        bytes.count >= 2 && bytes[bytes.startIndex] & 0x80 == 0 && bytes[bytes.startIndex + 1] & 0x07 != 0
    }

    private func processHEVC(_ payload: Data, into nalUnits: inout [Data], fragment: inout Data?) -> Bool {
        guard Self.validHEVCHeader(payload[...]) else { return false }
        switch (payload[0] >> 1) & 0x3F {
        case 0 ... 47:
            guard fragment == nil else { return false }
            nalUnits.append(payload)
            return true
        case 48: // Aggregation Packet
            guard fragment == nil else { return false }
            return depacketizeAP(payload, into: &nalUnits)
        case 49: // Fragmentation Unit
            guard payload.count > 3 else { return false }
            let fu = payload[2]
            let kind = fu & 0x3F
            let isStart = (fu & 0x80) != 0
            let isEnd = (fu & 0x40) != 0
            guard kind < 48, !(isStart && isEnd) else { return false }
            // RFC 7798 4.4.3: keep LayerId + TID, replace only the NAL type.
            let nalHeader: [UInt8] = [(payload[0] & 0x81) | (kind << 1), payload[1]]
            if isStart {
                guard fragment == nil else { return false }
                var head = Data(nalHeader)
                head.append(payload[3...])
                fragment = head
                return true
            }
            guard var open = fragment, open.prefix(2).elementsEqual(nalHeader) else { return false }
            open.append(payload[3...])
            fragment = isEnd ? nil : open
            if isEnd { nalUnits.append(open) }
            return true
        default:
            return false
        }
    }

    private func depacketizeAP(_ payload: Data, into nalUnits: inout [Data]) -> Bool {
        guard payload.count > 2 else { return false }
        var offset = 2
        while offset + 2 <= payload.count {
            let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            offset += 2
            guard size >= 2, offset + size <= payload.count else { return false }
            let nal = payload[offset ..< offset + size]
            guard Self.validHEVCHeader(nal), (nal[nal.startIndex] >> 1) & 0x3F < 48 else { return false }
            nalUnits.append(Data(nal))
            offset += size
        }
        return !nalUnits.isEmpty
    }
}

/// VideoToolbox decoder turning H.264/HEVC access units into CGImages.
public final class UURemoteRTPVideoDecoder: @unchecked Sendable {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var lastCodecName = ""
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?
    private var outputWidth = 0
    private var outputHeight = 0
    private let decodeQueue = DispatchQueue(label: "me.mizorewww.uu.rtp-decode", qos: .userInteractive)

    public init() {}

    /// Decodes one access unit into a CGImage, reconfiguring the session
    /// whenever the codec or parameter sets change.
    public func decode(accessUnit: UUVideoAccessUnit) -> CGImage? {
        extractParameterSets(from: accessUnit)
        guard let format = makeFormatDescription(for: accessUnit.codecName) else { return nil }
        if formatDescription == nil || !CMFormatDescriptionEqual(formatDescription!, otherFormatDescription: format) {
            formatDescription = format
            teardownSession()
            guard startSession(with: format) else { return nil }
        }
        guard let sample = makeSampleBuffer(accessUnit: accessUnit, format: format) else { return nil }
        var imageBuffer: CVPixelBuffer?
        var infoFlags = VTDecodeInfoFlags()
        // Synchronous decode: without _EnableAsynchronousDecompression the
        // output handler runs before the call returns, so `imageBuffer` is
        // populated immediately (the async variant returned before the
        // handler ran and always read nil).
        let status = VTDecompressionSessionDecodeFrame(
            decompressionSession!,
            sampleBuffer: sample,
            flags: [],
            infoFlagsOut: &infoFlags
        ) { _, _, imageBufferOut, _, _ in
            imageBuffer = imageBufferOut
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession!)
        guard status == noErr, let pixelBuffer = imageBuffer else { return nil }
        outputWidth = CVPixelBufferGetWidth(pixelBuffer)
        outputHeight = CVPixelBufferGetHeight(pixelBuffer)
        return Self.makeCGImage(from: pixelBuffer)
    }

    private func extractParameterSets(from accessUnit: UUVideoAccessUnit) {
        let isH265 = accessUnit.codecName.uppercased().contains("H265") || accessUnit.codecName.uppercased().contains("HEVC")
        for nal in accessUnit.nalUnits {
            guard !nal.isEmpty else { continue }
            let type = isH265 ? (nal[0] >> 1) & 0x3F : nal[0] & 0x1F
            if isH265 {
                // H.265 numbers them VPS 32, SPS 33, PPS 34.
                if type == 32 { vps = nal }
                if type == 33 { sps = nal }
                if type == 34 { pps = nal }
            } else {
                if type == 7 { sps = nal }
                if type == 8 { pps = nal }
            }
        }
    }

    private func makeFormatDescription(for codecName: String) -> CMVideoFormatDescription? {
        let isH265 = codecName.uppercased().contains("H265") || codecName.uppercased().contains("HEVC")
        let sets: [Data]
        if isH265 {
            guard let vps, let sps, let pps else { return nil }
            sets = [vps, sps, pps]
        } else {
            guard let sps, let pps else { return nil }
            sets = [sps, pps]
        }
        // The pointers must stay valid for the call: copy the sets into one
        // buffer and point into it while it is pinned.
        let joined = [UInt8](sets.reduce(Data(), +))
        let sizes = sets.map(\.count)
        var description: CMVideoFormatDescription?
        let status = joined.withUnsafeBufferPointer { buffer -> OSStatus in
            var offset = 0
            let pointers: [UnsafePointer<UInt8>] = sizes.map { size in
                defer { offset += size }
                return buffer.baseAddress! + offset
            }
            if isH265 {
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: sets.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &description
            )
        }
        return status == noErr ? description : nil
    }

    private func startSession(with format: CMVideoFormatDescription) -> Bool {
        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        // No output callback: frames are decoded with a handler each, which
        // VideoToolbox refuses on a session that has a callback.
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { return false }
        decompressionSession = session
        return true
    }

    private func teardownSession() {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
    }

    private func makeSampleBuffer(accessUnit: UUVideoAccessUnit, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let total = accessUnit.nalUnits.reduce(0) { $1.isEmpty ? $0 : $0 + 4 + $1.count }
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: total,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: total,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        // Each NAL unit as a 4-byte length and its bytes, one after another.
        // The block is allocated whole, so its data length is `total` from
        // the start and cannot say where the next one goes.
        var offset = 0
        for nal in accessUnit.nalUnits where !nal.isEmpty {
            var header = UInt32(nal.count).bigEndian
            status = CMBlockBufferReplaceDataBytes(
                with: &header,
                blockBuffer: block,
                offsetIntoDestination: offset,
                dataLength: 4
            )
            guard status == kCMBlockBufferNoErr else { return nil }
            offset += 4
            nal.withUnsafeBytes { raw in
                status = CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!,
                    blockBuffer: block,
                    offsetIntoDestination: offset,
                    dataLength: nal.count
                )
            }
            guard status == kCMBlockBufferNoErr else { return nil }
            offset += nal.count
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(accessUnit.timestamp), timescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        )
        guard status == noErr else { return nil }
        return sample
    }

    private static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        guard status == noErr else { return nil }
        return cgImage
    }

    public var outputSize: CGSize {
        CGSize(width: outputWidth, height: outputHeight)
    }
}

public extension UUVideoAccessUnit {
    /// NAL units out of an Annex-B byte stream (00 00 01 or 00 00 00 01
    /// before each), as WebRTC hands over an encoded H.264 / H.265 frame.
    static func nalUnits(annexB data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start {
                    var end = index
                    // A 4-byte start code's leading zero belongs to it.
                    if end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Data(bytes[start ..< end])) }
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count { units.append(Data(bytes[start...])) }
        return units
    }
}
