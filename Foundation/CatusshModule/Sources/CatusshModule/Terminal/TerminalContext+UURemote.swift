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
    /// Keystrokes and size changes go out every 15 ms, as the SSH loop
    /// picks them up.
    private static let pumpInterval: TimeInterval = 0.015

    /// Blocks until the terminal ends or the tab closes.
    func runUURemoteTerminal() {
        putInformation("[*] Connecting through UU Remote")
        let finished = DispatchSemaphore(value: 0)
        // The worker queue waits on `finished`; the context outlives this.
        nonisolated(unsafe) let context = self
        let machine = machine
        let initial = terminalSize

        onMainThread {
            MainActor.assumeIsolated {
                let link = UUTerminalLink(machine: machine, finished: finished)
                context.uuTerminalLink = link
                link.connect(context: context, size: initial)
            }
        }

        // The pump: what is typed goes out, the size follows the view, and
        // a connection that drops ends the tab.
        while !closed {
            if finished.wait(timeout: .now() + Self.pumpInterval) == .success { break }
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

/// One tab's terminal on a device's UU connection. Everything here runs on
/// the main thread, so the connection is released exactly once: by `end`,
/// or by `connect` itself when the tab closed while it was connecting.
@MainActor
private final class UUTerminalLink {
    let machine: RDMachine
    let finished: DispatchSemaphore
    private var driver: UURemoteDriver?
    private var terminalID: UInt32?
    private var sentSize: CGSize = .zero
    private var ended = false
    private let decoder = UTF8StreamDecoder()

    init(machine: RDMachine, finished: DispatchSemaphore) {
        self.machine = machine
        self.finished = finished
    }

    func connect(context: TerminalContext, size: CGSize) {
        Task { @MainActor in
            do {
                let connection = try await UURemoteConnections.shared.acquire(for: machine)
                guard !ended else {
                    UURemoteConnections.shared.release(machine, driver: connection)
                    return
                }
                driver = connection
                sentSize = size
                terminalID = connection.openTerminal(
                    cols: Int(max(size.width, 8)), rows: Int(max(size.height, 8))
                ) { [weak self, weak context] frame in
                    guard let self, let context else { return }
                    self.handle(frame, context: context)
                }
            } catch {
                context.putInformation("[!] " + error.localizedDescription)
                finished.signal()
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
                finished.signal()
            }
        case .exit:
            let code = UUTerminalJSON.decodeExit(frame.payload).map { " (exit \($0))" } ?? ""
            context.putInformation("\r\n[*] Shell ended\(code)")
            finished.signal()
        case .close:
            finished.signal()
        default:
            break
        }
    }

    func pump(typed: String, size: CGSize, context: TerminalContext) {
        guard let driver, let id = terminalID, !ended else { return }
        if driver.isClosed {
            context.putInformation("\r\n[!] The UU Remote connection dropped.")
            finished.signal()
            return
        }
        if !typed.isEmpty { driver.sendTerminalStdin(Data(typed.utf8), sessionID: id) }
        if size != sentSize, size.width >= 8, size.height >= 8 {
            sentSize = size
            driver.sendTerminalResize(cols: Int(size.width), rows: Int(size.height), sessionID: id)
        }
    }

    func end() {
        guard !ended else { return }
        ended = true
        guard let driver else { return }
        if let id = terminalID { driver.closeTerminal(id) }
        UURemoteConnections.shared.release(machine, driver: driver)
    }
}

/// UTF-8 text out of chunks that may split a character between them.
final class UTF8StreamDecoder: @unchecked Sendable {
    private var pending = Data()

    func decode(_ chunk: Data) -> String {
        pending.append(chunk)
        // An empty frame, with nothing held back: nothing to decode (and no
        // range of trailing bytes to look at).
        guard !pending.isEmpty else { return "" }
        // Hold back an incomplete character at the end, at most 3 bytes.
        var end = pending.count
        for back in 1 ... min(3, pending.count) {
            let byte = pending[pending.startIndex + pending.count - back]
            if byte & 0xC0 == 0x80 { continue } // continuation: look further
            let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            if needed > back { end = pending.count - back }
            break
        }
        let complete = pending.prefix(end)
        pending = Data(pending.dropFirst(end))
        return String(decoding: complete, as: UTF8.self)
    }
}
