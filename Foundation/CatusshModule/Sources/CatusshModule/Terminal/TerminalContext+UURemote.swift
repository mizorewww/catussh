//
//  TerminalContext+UURemote.swift
//  CatusshModule
//
//  A terminal on a UU Remote device: the host's own shell over the device's
//  UU connection (TERM frames on its binary channel), no SSH. Runs on the
//  session's worker queue like the SSH loop, and ends the same way.
//

import Foundation
import ObjectiveC

extension TerminalContext {
    /// Event-driven UU Remote terminal loop: wakes immediately on keystrokes,
    /// resize, or connection close, with a 1s liveness check instead of 66Hz polling.
    func runUURemoteTerminal() {
        putInformation("[*] Connecting through UU Remote")
        let finished = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let context = self
        let machine = machine
        let initial = terminalSize

        onMainThread {
            MainActor.assumeIsolated {
                let link = UUTerminalLink(machine: machine, finished: finished, wake: context.uuWakeSemaphore)
                context.uuTerminalLink = link
                link.connect(context: context, size: initial)
            }
        }

        while !closed {
            if finished.wait(timeout: .now()) == .success { break }
            _ = uuWakeSemaphore.wait(timeout: .now() + 1.0)
            if finished.wait(timeout: .now()) == .success || closed { break }
            let typed = getBuffer()
            let size = terminalSize
            onMainThread {
                MainActor.assumeIsolated { context.uuTerminalLink?.pump(typed: typed, size: size, context: context) }
            }
        }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                context.uuTerminalLink?.end()
                context.uuTerminalLink = nil
            }
            done.signal()
        }
        done.wait()
    }
}

private nonisolated(unsafe) var uuTerminalLinkKey: UInt8 = 0

extension TerminalContext {
    /// The UU terminal behind this tab; main thread only.
    @MainActor fileprivate var uuTerminalLink: UUTerminalLink? {
        get { objc_getAssociatedObject(self, &uuTerminalLinkKey) as? UUTerminalLink }
        set { objc_setAssociatedObject(self, &uuTerminalLinkKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

@MainActor
private final class UUTerminalLink {
    let machine: RDMachine
    let finished: DispatchSemaphore
    let wake: DispatchSemaphore
    private var driver: UURemoteDriver?
    private var terminalID: UInt32?
    private var sentSize: CGSize = .zero
    private var openedAt = Date.distantFuture
    private var ended = false
    private let decoder = UTF8StreamDecoder()

    init(machine: RDMachine, finished: DispatchSemaphore, wake: DispatchSemaphore) {
        self.machine = machine
        self.finished = finished
        self.wake = wake
    }

    func connect(context: TerminalContext, size: CGSize) {
        Task { @MainActor [weak self, weak context] in
            guard let self, let context else { return }
            do {
                let connection = try await UURemoteConnections.shared.acquire(for: self.machine)
                guard !self.ended else {
                    UURemoteConnections.shared.release(self.machine, driver: connection)
                    return
                }
                self.driver = connection
                self.sentSize = size
                let attaching = context.uuSessionID
                self.openedAt = attaching == nil ? Date() : .distantPast
                let id = connection.openTerminal(
                    sessionID: attaching,
                    cols: Int(max(size.width, 8)), rows: Int(max(size.height, 8))
                ) { [weak self, weak context] frame in
                    guard let self, let context else { return }
                    self.handle(frame, context: context)
                }
                self.terminalID = id
                context.uuSessionID = id
                if attaching != nil {
                    context.putInformation("[*] Resumed the session on \(self.machine.name)")
                    let cols = Int(max(size.width, 8)), rows = Int(max(size.height, 8))
                    connection.sendTerminalResize(cols: cols, rows: max(rows - 1, 8), sessionID: id)
                    connection.sendTerminalResize(cols: cols, rows: rows, sessionID: id)
                }
                self.wake.signal()
            } catch {
                context.putInformation("[!] " + error.localizedDescription)
                self.finished.signal()
                self.wake.signal()
            }
        }
    }

    private func handle(_ frame: UUTerminalFrame, context: TerminalContext) {
        switch frame.kind {
        case .stdout, .error:
            let text = decoder.decode(frame.payload)
            if !text.isEmpty { context.surface.write(text) }
        case .openResp:
            if let reply = UUTerminalJSON.decodeOpenResponse(frame.payload), reply.code != 0 {
                context.putInformation("[!] The device refused the terminal: \(reply.message) (\(reply.code))")
                context.uuSessionID = nil
                finished.signal()
                wake.signal()
            }
        case .exit:
            let code = UUTerminalJSON.decodeExit(frame.payload).map { " (exit \($0))" } ?? ""
            context.putInformation("\r\n[*] Shell ended\(code)")
            context.uuSessionID = nil
            finished.signal()
            wake.signal()
        case .close:
            finished.signal()
            wake.signal()
        default:
            break
        }
    }

    func pump(typed: String, size: CGSize, context: TerminalContext) {
        guard let driver, let id = terminalID, !ended else { return }
        if driver.isClosed {
            context.putInformation("\r\n[!] The UU Remote connection dropped.")
            finished.signal()
            wake.signal()
            return
        }
        let input = Date().timeIntervalSince(openedAt) < Self.startupReplyWindow ? TerminalReplies.dropping(from: typed) : typed
        if !input.isEmpty { driver.sendTerminalStdin(Data(input.utf8), sessionID: id) }
        if size != sentSize, size.width >= 8, size.height >= 8 {
            sentSize = size
            driver.sendTerminalResize(cols: Int(size.width), rows: Int(size.height), sessionID: id)
        }
    }

    static let startupReplyWindow: TimeInterval = 3

    func end() {
        guard !ended else { return }
        ended = true
        guard let driver else { return }
        if let id = terminalID, !driver.isClosed { driver.detachTerminal(id) }
        UURemoteConnections.shared.release(machine, driver: driver)
    }
}

/// UTF-8 text out of chunks that may split a character between them.
final class UTF8StreamDecoder: @unchecked Sendable {
    private var pending = Data()

    func decode(_ chunk: Data) -> String {
        pending.append(chunk)
        guard !pending.isEmpty else { return "" }
        var end = pending.count
        for back in 1 ... min(3, pending.count) {
            let byte = pending[pending.startIndex + pending.count - back]
            if byte & 0xC0 == 0x80 { continue }
            let needed: Int
            switch byte {
            case 0xC2...0xDF: needed = 2
            case 0xE0...0xEF: needed = 3
            case 0xF0...0xF4: needed = 4
            default: needed = 1
            }
            if needed > back { end = pending.count - back }
            break
        }
        let complete = pending.prefix(end)
        if end == pending.count {
            pending.removeAll(keepingCapacity: true)
        } else {
            pending = Data(pending.dropFirst(end))
        }
        return String(decoding: complete, as: UTF8.self)
    }
}

enum TerminalReplies {
    static func dropping(from text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return replyPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
    }

    private static let replyPattern = try! NSRegularExpression(pattern: [
        "\u{1B}\\[[?>=][0-9;]*c",
        "\u{1B}P>\\|[^\u{1B}]*\u{1B}\\\\",
        "\u{1B}\\][0-9]+;rgb:[^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)",
        "\u{1B}\\[\\?[0-9;]*\\$y",
    ].joined(separator: "|"))
}
