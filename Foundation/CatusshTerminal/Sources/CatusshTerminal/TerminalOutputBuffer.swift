import Foundation

/// Ghostty caps output received before attachment at 1 MiB. Keep startup output
/// here until the surface exists, so an early SSH banner/batch result is not lost,
/// bounded at 4 MiB so an unattached terminal cannot grow without bound.
final class TerminalOutputBuffer: @unchecked Sendable {
    private static let maxPendingBytes = 4 * 1024 * 1024

    private let lock = NSLock()
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var attached = false
    private let receive: @Sendable (Data) -> Void

    init(receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let deliverNow = lock.withLock {
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
