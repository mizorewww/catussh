//
//  VNCZlibStream.swift
//  CatusshModule
//
//  A persistent zlib inflate stream. ZRLE runs one continuous compressed
//  stream across the whole connection — each rectangle feeds another
//  chunk — so `inflate` state is kept instead of reinitialized per rect.
//

import Foundation
import zlib

final class VNCZlibStream: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case inflateInit(Int32)
        case inflate(Int32)
    }

    private var stream = z_stream()
    private let lock = NSLock()
    private var inited = false

    init() {
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
    }

    /// Inflates `input` completely. The output size of one ZRLE rectangle is
    /// bounded (64×64 tile payloads, at most a few hundred KiB).
    func inflate(_ input: Data, expectedMinimumOutput: Int = 0) throws -> Data {
        try lock.withLock {
            if !inited {
                let status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                guard status == Z_OK else { throw Failure.inflateInit(status) }
                inited = true
            }
            var output = Data()
            output.reserveCapacity(max(expectedMinimumOutput, 64 * 1024))
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            try input.withUnsafeBytes { inputBuffer in
                guard let base = inputBuffer.baseAddress else { return }
                stream.next_in = UnsafeMutablePointer<UInt8>(mutating: base.assumingMemoryBound(to: UInt8.self))
                stream.avail_in = uInt(inputBuffer.count)
                var reachedEnd = false
                while !reachedEnd {
                    let status = chunk.withUnsafeMutableBytes { outputBuffer -> Int32 in
                        stream.next_out = outputBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        stream.avail_out = uInt(outputBuffer.count)
                        return zlib.inflate(&stream, Z_NO_FLUSH)
                    }
                    let produced = chunk.count - Int(stream.avail_out)
                    if produced > 0 { output.append(contentsOf: chunk.prefix(produced)) }
                    switch status {
                    case Z_OK, Z_BUF_ERROR:
                        if Int(stream.avail_in) == 0, produced == 0 { reachedEnd = true }
                    case Z_STREAM_END:
                        reachedEnd = true
                    default:
                        throw Failure.inflate(status)
                    }
                }
            }
            return output
        }
    }

    deinit {
        if inited { inflateEnd(&stream) }
    }
}
