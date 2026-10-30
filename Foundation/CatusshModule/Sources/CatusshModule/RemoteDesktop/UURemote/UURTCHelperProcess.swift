//
//  UURTCHelperProcess.swift
//  CatusshModule
//
//  The WebRTC page in a helper process. Mac Catalyst's WebKit has no
//  RTCPeerConnection, so the Mac app carries a small macOS tool
//  (catussh-rtc, in Contents/MacOS) whose WebKit has one, and drives the
//  page there: newline-delimited JSON over its stdin and stdout.
//

#if targetEnvironment(macCatalyst)
    import Darwin
    import Foundation

    final class UURTCHelperProcess: @unchecked Sendable {
        static var executableURL: URL? {
            Bundle.main.url(forAuxiliaryExecutable: "catussh-rtc")
        }

        /// Every message the page posts, on the main thread.
        var onEvent: ((Any) -> Void)?
        /// The page loaded (true) or failed to (false, with why); main thread.
        var onReady: ((Bool, String?) -> Void)?

        /// Foundation's Process is not available to Mac Catalyst code; the
        /// helper is started with posix_spawn and two pipes.
        private var pid: pid_t = 0
        private let input: FileHandle
        private let output: FileHandle
        private let lock = NSLock()
        private var pending: [Int: CheckedContinuation<String?, Error>] = [:]
        private var nextID = 0
        private var received = Data()

        init(executable: URL) throws {
            var toHelper: [Int32] = [0, 0]
            var fromHelper: [Int32] = [0, 0]
            guard pipe(&toHelper) == 0, pipe(&fromHelper) == 0 else {
                throw RemoteDesktopFailure("Could not start the WebRTC helper (\(String(cString: strerror(errno)))).")
            }
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_adddup2(&actions, toHelper[0], STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, fromHelper[1], STDOUT_FILENO)
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
            for fd in [toHelper[1], fromHelper[0]] { posix_spawn_file_actions_addclose(&actions, fd) }
            let path = executable.path
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
            defer { argv.forEach { free($0) } }
            let status = posix_spawn(&pid, path, &actions, nil, &argv, environ)
            close(toHelper[0])
            close(fromHelper[1])
            guard status == 0 else {
                close(toHelper[1])
                close(fromHelper[0])
                throw RemoteDesktopFailure("Could not start the WebRTC helper (\(String(cString: strerror(status)))).")
            }
            // A write to a helper that died must fail, not end the app.
            _ = fcntl(toHelper[1], F_SETNOSIGPIPE, 1)
            input = FileHandle(fileDescriptor: toHelper[1], closeOnDealloc: true)
            output = FileHandle(fileDescriptor: fromHelper[0], closeOnDealloc: true)
            output.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // End of its output: the helper is gone.
                    handle.readabilityHandler = nil
                    self?.failAll("The WebRTC helper stopped.")
                } else {
                    self?.receive(chunk)
                }
            }
        }

        deinit {
            output.readabilityHandler = nil
            // Closing its stdin ends it; the signal is for one that hangs.
            try? input.close()
            let pid = pid
            kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; waitpid(pid, &status, 0) }
        }

        func load(html: String, baseURL: String) {
            write(["load": html, "base": baseURL])
        }

        /// The value of an expression in the page, awaited there; the page's
        /// functions answer with strings (an SDP, "ok") or nothing.
        func evaluate(_ script: String) async throws -> String? {
            try await withCheckedThrowingContinuation { continuation in
                let id: Int = lock.withLock {
                    nextID += 1
                    pending[nextID] = continuation
                    return nextID
                }
                write(["id": id, "js": script])
            }
        }

        private func write(_ object: [String: Any]) {
            guard var line = try? JSONSerialization.data(withJSONObject: object) else { return }
            line.append(0x0A)
            try? input.write(contentsOf: line)
        }

        /// On the pipe's reader queue: whole lines, one message each.
        private func receive(_ chunk: Data) {
            received.append(chunk)
            while let newline = received.firstIndex(of: 0x0A) {
                let line = received[received.startIndex ..< newline]
                received = Data(received[received.index(after: newline)...])
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                dispatch(message)
            }
        }

        private func dispatch(_ message: [String: Any]) {
            if let id = message["id"] as? Int {
                guard let continuation = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
                if let error = message["error"] as? String {
                    continuation.resume(throwing: RemoteDesktopFailure(error))
                } else {
                    continuation.resume(returning: message["ok"] as? String)
                }
            } else if let event = message["event"] {
                nonisolated(unsafe) let event = event
                DispatchQueue.main.async { self.onEvent?(event) }
            } else if let ready = message["ready"] as? Bool {
                let reason = message["error"] as? String
                DispatchQueue.main.async { self.onReady?(ready, reason) }
            }
        }

        private func failAll(_ reason: String) {
            let waiting = lock.withLock {
                defer { pending.removeAll() }
                return Array(pending.values)
            }
            waiting.forEach { $0.resume(throwing: RemoteDesktopFailure(reason)) }
            DispatchQueue.main.async { self.onReady?(false, reason) }
        }
    }
#endif
