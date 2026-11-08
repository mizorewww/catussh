import Foundation

/// Registration may happen on an SSH worker. Delivery stays on the UI thread,
/// like the old WebKit message handlers. Never invoke a client while holding the lock.
final class TerminalCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var input: ((String) -> Void)?
    private var title: ((String) -> Void)?
    private var bell: (() -> Void)?
    private var resize: ((CGSize) -> Void)?
    private var size = CGSize(width: 80, height: 40)
    private var requestedFontSize = 14
    private var decoder = TerminalInputDecoder()

    func setInput(_ callback: ((String) -> Void)?) {
        lock.withLock {
            input = callback
            decoder.reset()
        }
    }
    func setTitle(_ callback: ((String) -> Void)?) { lock.withLock { title = callback } }
    func setBell(_ callback: (() -> Void)?) { lock.withLock { bell = callback } }
    func setResize(_ callback: ((CGSize) -> Void)?) {
        lock.withLock { resize = callback }
        DispatchQueue.main.async { [self] in
            let (callback, value) = lock.withLock { (resize, size) }
            callback?(value)
        }
    }

    var terminalSize: CGSize { lock.withLock { size } }
    var fontSize: Int { lock.withLock { requestedFontSize } }
    func setFontSize(_ value: Int) { lock.withLock { requestedFontSize = value } }

    func receiveInput(_ data: Data) {
        DispatchQueue.main.async { [self] in
            let (callback, text) = lock.withLock { (input, decoder.append(data)) }
            if !text.isEmpty { callback?(text) }
        }
    }

    func receiveSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        DispatchQueue.main.async { [self] in
            let value = CGSize(width: columns, height: rows)
            let callback = lock.withLock {
                size = value
                return resize
            }
            callback?(value)
        }
    }

    @MainActor func receiveTitle(_ value: String) { lock.withLock { title }?(value) }
    @MainActor func receiveBell() { lock.withLock { bell }?() }
}

/// NSRemoteShell accepts String input. Hold incomplete UTF-8 suffixes instead of
/// replacing a Chinese character/emoji when Ghostty splits it across callbacks.
struct TerminalInputDecoder {
    private var pending = Data()

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
    }

    mutating func append(_ data: Data) -> String {
        pending.append(data)
        guard !pending.isEmpty else { return "" }
        var end = pending.count
        for back in 1 ... min(3, pending.count) {
            let byte = pending[pending.startIndex + pending.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let count: Int
            switch byte {
            case 0xC2...0xDF: count = 2
            case 0xE0...0xEF: count = 3
            case 0xF0...0xF4: count = 4
            default: count = 1
            }
            if count > back { end = pending.count - back }
            break
        }
        let text = String(decoding: pending.prefix(end), as: UTF8.self)
        if end == pending.count {
            pending.removeAll(keepingCapacity: true)
        } else {
            pending = Data(pending.dropFirst(end))
        }
        return text
    }
}
