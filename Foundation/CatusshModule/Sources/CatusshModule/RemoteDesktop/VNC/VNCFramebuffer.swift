//
//  VNCFramebuffer.swift
//  CatusshModule
//
//  The pixel store the RFB decoders write into, and the CGImage the stage
//  view shows. Pixels are 32-bit words `0xAARRGGBB`, whose little-endian
//  bytes are B, G, R, A — the "BGRA" layout CGImage wants with
//  `.byteOrder32Little` + `.noneSkipFirst`.
//

import CoreGraphics
import Foundation

final class VNCFramebuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pixels: [UInt32] = []
    private(set) var width = 0
    private(set) var height = 0

    var size: CGSize {
        lock.withLock { CGSize(width: width, height: height) }
    }

    /// Resizes the buffer; existing contents are discarded beyond the new
    /// edges and new pixels start transparent-black.
    func resize(width: Int, height: Int) {
        lock.withLock {
            guard width > 0, height > 0 else { return }
            self.width = width
            self.height = height
            pixels = [UInt32](repeating: 0xFF00_0000, count: width * height)
        }
    }

    /// Writes one canonical pixel.
    func put(x: Int, y: Int, pixel: UInt32) {
        lock.withLock {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            pixels[y * width + x] = pixel
        }
    }

    /// Fills a rectangle with one canonical pixel, clipped to the buffer.
    func fill(x: Int, y: Int, width w: Int, height h: Int, pixel: UInt32) {
        lock.withLock {
            let x0 = max(0, x), y0 = max(0, y)
            let x1 = min(width, x + w), y1 = min(height, y + h)
            guard x1 > x0, y1 > y0 else { return }
            for row in y0 ..< y1 {
                for column in x0 ..< x1 {
                    pixels[row * width + column] = pixel
                }
            }
        }
    }

    /// Copies a rectangle inside the buffer (CopyRect).
    func copy(fromX: Int, fromY: Int, toX: Int, toY: Int, width w: Int, height h: Int) {
        lock.withLock {
            guard w > 0, h > 0 else { return }
            // Rows must be moved in an order that does not smear overlapping
            // regions; collect the source rows first when they overlap.
            var source: [UInt32] = []
            source.reserveCapacity(w * h)
            for row in 0 ..< h {
                for column in 0 ..< w {
                    let sx = fromX + column, sy = fromY + row
                    source.append(
                        (sx >= 0 && sy >= 0 && sx < width && sy < height)
                            ? pixels[sy * width + sx] : 0xFF00_0000
                    )
                }
            }
            for row in 0 ..< h {
                for column in 0 ..< w {
                    let tx = toX + column, ty = toY + row
                    guard tx >= 0, ty >= 0, tx < width, ty < height else { continue }
                    pixels[ty * width + tx] = source[row * w + column]
                }
            }
        }
    }

    /// Writes a run of canonical pixels starting at (x, y), wrapping to the
    /// next row — the shape the ZRLE decoder produces.
    func putRun(x: Int, y: Int, width w: Int, pixels line: ArraySlice<UInt32>) {
        lock.withLock {
            var offset = 0
            for pixel in line {
                let px = x + offset % w, py = y + offset / w
                if px >= 0, py >= 0, px < width, py < height {
                    self.pixels[py * width + px] = pixel
                }
                offset += 1
            }
        }
    }

    /// Reads one canonical pixel.
    func pixel(x: Int, y: Int) -> UInt32? {
        lock.withLock {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            return pixels[y * width + x]
        }
    }

    /// A snapshot CGImage of the whole framebuffer. The copy is what a
    /// `CGDataProvider` needs to outlive the lock; frames are large but the
    /// copy is cheap next to decoding.
    func makeImage() -> CGImage? {
        lock.withLock {
            guard width > 0, height > 0 else { return nil }
            let data = pixels.withUnsafeBytes { Data($0) }
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        }
    }
}
