import Foundation

/// Ghostty caps output received before attachment at 1 MiB. Keep startup output
/// here until the surface exists, so an early SSH banner/batch result is not lost,
/// bounded at 4 MiB so an unattached terminal cannot grow without bound.
final class TerminalOutputBuffer: @unchecked Sendable {
    private static let maxPendingBytes = 4 * 1024 * 1024
    private static let maxTranscriptCharacters = 256 * 1024

    private let lock = NSLock()
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var attached = false
    private var recentText = ""
    private let receive: @Sendable (Data) -> Void

    init(receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let chunkStr = String(decoding: data, as: UTF8.self)
        let deliverNow = lock.withLock {
            appendTranscriptLocked(chunkStr)
            if attached { return true }
            if data.count >= Self.maxPendingBytes {
                pending = [data.suffix(Self.maxPendingBytes)]
                pendingBytes = Self.maxPendingBytes
                return false
            }
            pending.append(data)
            pendingBytes += data.count
            while pendingBytes > Self.maxPendingBytes, !pending.isEmpty {
                let firstCount = pending[0].count
                let excess = pendingBytes - Self.maxPendingBytes
                if firstCount <= excess {
                    pending.removeFirst()
                    pendingBytes -= firstCount
                } else {
                    pending[0] = Data(pending[0].dropFirst(excess))
                    pendingBytes -= excess
                }
            }
            return false
        }
        if deliverNow { receive(data) }
    }

    private func appendTranscriptLocked(_ chunk: String) {
        let stripped = Self.stripANSI(chunk)
        guard !stripped.isEmpty else { return }
        recentText += stripped
        if recentText.count > Self.maxTranscriptCharacters {
            recentText = String(recentText.suffix(Self.maxTranscriptCharacters))
        }
    }

    func transcriptLines() -> [String] {
        let snap = lock.withLock { recentText }
        return snap
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func stripANSI(_ input: String) -> String {
        guard input.contains("\u{1B}") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var iter = input.unicodeScalars.makeIterator()
        while let ch = iter.next() {
            if ch == "\u{1B}" {
                guard let next = iter.next() else { break }
                if next == "[" {
                    while let c = iter.next() {
                        if (0x40 ... 0x7E).contains(c.value) { break }
                    }
                } else if next == "]" {
                    while let c = iter.next() {
                        if c == "\u{07}" || c == "\u{1B}" { break }
                    }
                }
            } else {
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    func setAttached(_ value: Bool) {
        let replay: [Data] = lock.withLock {
            attached = value
            guard value else { return [] }
            defer {
                pending.removeAll(keepingCapacity: false)
                pendingBytes = 0
            }
            return pending
        }
        for data in replay { receive(data) }
    }
}
