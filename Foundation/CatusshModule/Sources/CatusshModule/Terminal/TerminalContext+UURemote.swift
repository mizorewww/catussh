//
//  TerminalContext+UURemote.swift
//  CatusshModule
//
//  A terminal on a UU Remote device: the host's own shell over the device's
//  UU connection (TERM frames on its binary channel), no SSH. Runs on the
//  session's worker queue like the SSH loop, and ends the same way.
//

import Foundation

extension TerminalContext {
    /// Keystrokes and size changes go out every 15 ms, as the SSH loop
    /// picks them up.
    private static let pumpInterval: TimeInterval = 0.015

    /// Blocks until the terminal ends or the tab closes.
    func runUURemoteTerminal() {
        let machine = machine
        putInformation("[*] Connecting through UU Remote")
        let finished = DispatchSemaphore(value: 0)
        let decoder = UTF8StreamDecoder()
        nonisolated(unsafe) var driver: UURemoteDriver?
        nonisolated(unsafe) var terminalID: UInt32?
        var size = terminalSize
        let initial = size
        // The worker queue waits on `finished`; the context outlives this.
        nonisolated(unsafe) let context = self

        onMainThread {
            Task { @MainActor in
                do {
                    let connection = try await UURemoteConnections.shared.acquire(for: machine)
                    driver = connection
                    guard !context.closed else { finished.signal(); return }
                    terminalID = connection.openTerminal(
                        cols: Int(max(initial.width, 8)), rows: Int(max(initial.height, 8))
                    ) { [weak context] frame in
                        guard let self = context else { return }
                        switch frame.kind {
                        case .stdout, .error:
                            let text = decoder.decode(frame.payload)
                            if !text.isEmpty { self.surface.write(text) }
                        case .openResp:
                            if let reply = UUTerminalJSON.decodeOpenResponse(frame.payload), reply.code != 0 {
                                self.putInformation("[!] The device refused the terminal: \(reply.message) (\(reply.code))")
                                finished.signal()
                            }
                        case .exit:
                            let code = UUTerminalJSON.decodeExit(frame.payload).map { " (exit \($0))" } ?? ""
                            self.putInformation("\r\n[*] Shell ended\(code)")
                            finished.signal()
                        case .close:
                            finished.signal()
                        default:
                            break
                        }
                    }
                } catch {
                    context.putInformation("[!] " + error.localizedDescription)
                    finished.signal()
                }
            }
        }

        // The pump: what is typed goes out, the size follows the view.
        while !closed {
            if finished.wait(timeout: .now() + Self.pumpInterval) == .success { break }
            guard let id = terminalID else { continue }
            let typed = getBuffer()
            let current = terminalSize
            onMainThread {
                guard let driver else { return }
                if !typed.isEmpty { driver.sendTerminalStdin(Data(typed.utf8), sessionID: id) }
                if current != size, current.width >= 8, current.height >= 8 {
                    driver.sendTerminalResize(cols: Int(current.width), rows: Int(current.height), sessionID: id)
                }
            }
            size = current
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id = terminalID { driver?.closeTerminal(id) }
                if driver != nil { UURemoteConnections.shared.release(machine) }
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}

/// UTF-8 text out of chunks that may split a character between them.
final class UTF8StreamDecoder: @unchecked Sendable {
    private var pending = Data()

    func decode(_ chunk: Data) -> String {
        pending.append(chunk)
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
