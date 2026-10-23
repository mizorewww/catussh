//
//  CloudflareAccessTunnel.swift
//  CatusshModule
//
//  What `cloudflared access ssh --hostname <host>` does, without cloudflared,
//  which a sandboxed app cannot run: a WebSocket to https://<host>, whose
//  binary messages Cloudflare's edge relays to the SSH server behind the
//  Cloudflare Tunnel. libssh2 wants a socket, so it gets one end of a socket
//  pair and the tunnel moves bytes between the other end and the WebSocket.
//

import Darwin
import Foundation
import NSRemoteShell

final class CloudflareAccessTunnel: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Why no tunnel could be opened, worded for the terminal.
    struct Failure: Error {
        let message: String
    }

    private let hostname: String
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    private let opening = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var opened = false
    private var redirect: URL?
    private var finished = false

    /// The tunnel's end of the socket pair. Written by the receive side and
    /// closed by the read side, both under `fdLock`, so a closed descriptor
    /// number is never written to after the system hands it out again.
    private let fdLock = NSLock()
    private var localFD: Int32 = -1
    private var localClosed = false

    private init(hostname: String) {
        self.hostname = hostname
    }

    /// Opens a tunnel and returns the descriptor the SSH session reads and
    /// writes. Blocks the calling thread until the WebSocket is open, for at
    /// most `timeout` seconds.
    static func open(
        hostname: String,
        serviceTokenID: String,
        serviceTokenSecret: String,
        timeout: TimeInterval
    ) -> Result<Int32, Failure> {
        let host = normalized(hostname)
        guard !host.isEmpty, let url = URL(string: "wss://\(host)/") else {
            return .failure(Failure(message: "\"\(hostname)\" is not a host name Cloudflare can serve."))
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if !serviceTokenID.isEmpty || !serviceTokenSecret.isEmpty {
            request.setValue(serviceTokenID, forHTTPHeaderField: "Cf-Access-Client-Id")
            request.setValue(serviceTokenSecret, forHTTPHeaderField: "Cf-Access-Client-Secret")
        }
        let tunnel = CloudflareAccessTunnel(hostname: host)
        return tunnel.start(request: request, timeout: timeout, usesServiceToken: !serviceTokenID.isEmpty)
    }

    /// "https://host/" and "host:443" as typed are the host itself.
    static func normalized(_ hostname: String) -> String {
        var host = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if host.hasSuffix(":443") { host.removeLast(4) }
        return host
    }

    private func start(request: URLRequest, timeout: TimeInterval, usesServiceToken: Bool) -> Result<Int32, Failure> {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            return .failure(Failure(message: "Could not make a socket for the Cloudflare tunnel (errno \(errno))."))
        }
        for fd in pair {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        localFD = pair[1]

        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        // An SSH packet is at most 256 KiB; the default 1 MiB leaves room.
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()

        let inTime = opening.wait(timeout: .now() + timeout) == .success
        let (isOpen, redirect) = stateLock.withLock { (opened, self.redirect) }
        guard isOpen else {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            let error = task.error
            finish()
            close(pair[0])
            closeLocal()
            return .failure(failure(inTime: inTime, status: status, redirect: redirect, error: error, usesServiceToken: usesServiceToken))
        }

        receiveNext()
        let reader = Thread { [self] in pumpToWebSocket() }
        reader.name = "me.mizorewww.cloudflare-tunnel.\(hostname)"
        reader.start()
        return .success(pair[0])
    }

    private func failure(inTime: Bool, status: Int?, redirect: URL?, error: Error?, usesServiceToken: Bool) -> Failure {
        let asksForSignIn = redirect?.path.contains("/cdn-cgi/access/") == true
            || status == 302 || status == 401 || status == 403
        if asksForSignIn {
            if usesServiceToken {
                return Failure(message: "Cloudflare Access did not accept the service token for \(hostname). Check its Client ID and Secret, and that the application's policy allows it (Service Auth).")
            }
            return Failure(message: "\(hostname) is protected by Cloudflare Access and asks to sign in. Add a service token to the server (Edit Server › Cloudflare Access): signing in with a browser is not supported yet.")
        }
        if !inTime {
            return Failure(message: "Timed out reaching \(hostname) through Cloudflare.")
        }
        var message = "Could not open a Cloudflare tunnel to \(hostname)"
        if let status { message += " (HTTP \(status))" }
        if let error {
            var reason = error.localizedDescription
            while reason.hasSuffix(".") { reason.removeLast() }
            message += ": \(reason)"
        }
        return Failure(message: message + ".")
    }

    // MARK: Moving bytes

    /// SSH session → WebSocket, one message per read, the next read only once
    /// the message is sent so a slow link pushes back on libssh2.
    private func pumpToWebSocket() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let sent = DispatchSemaphore(value: 0)
        let failed = Flag()
        while true {
            let count = buffer.withUnsafeMutableBytes { read(localFD, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            task.send(.data(Data(buffer[0 ..< count]))) { error in
                if error != nil { failed.set() }
                sent.signal()
            }
            sent.wait()
            if failed.isSet { break }
        }
        finish()
        closeLocal()
    }

    /// WebSocket → SSH session.
    private func receiveNext() {
        task.receive { [self] result in
            switch result {
            case let .success(.data(data)):
                if write(data) { receiveNext() } else { finish() }
            case let .success(.string(text)):
                if write(Data(text.utf8)) { receiveNext() } else { finish() }
            case .failure:
                finish()
            @unknown default:
                finish()
            }
        }
    }

    private func write(_ data: Data) -> Bool {
        fdLock.withLock {
            guard !localClosed else { return false }
            return data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(localFD, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { return false }
                    offset += written
                }
                return true
            }
        }
    }

    /// Ends both directions once: the WebSocket is closed, and the socket is
    /// shut down so the read side wakes up and the SSH session sees the end.
    private func finish() {
        let first = stateLock.withLock {
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        fdLock.withLock {
            if !localClosed { shutdown(localFD, SHUT_RDWR) }
        }
    }

    private func closeLocal() {
        fdLock.withLock {
            guard !localClosed else { return }
            localClosed = true
            close(localFD)
        }
    }

    // MARK: URLSession

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        stateLock.withLock { opened = true }
        opening.signal()
    }

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didCloseWith _: URLSessionWebSocketTask.CloseCode, reason _: Data?) {
        finish()
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError _: Error?) {
        let wasOpen = stateLock.withLock { opened }
        if wasOpen { finish() } else { opening.signal() }
    }

    /// Access answers a request without credentials with a redirect to its
    /// sign-in page; following it would only fetch that page.
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        stateLock.withLock { redirect = request.url }
        completionHandler(nil)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

// MARK: - The shell's side

private nonisolated(unsafe) let tunnelFailureKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

public extension NSRemoteShell {
    /// Why the last connection through Cloudflare could not be made, for the
    /// person; nil after a connection that got through, or one made over TCP.
    var tunnelFailure: String? {
        get { objc_getAssociatedObject(self, tunnelFailureKey) as? String }
        set { objc_setAssociatedObject(self, tunnelFailureKey, newValue, .OBJC_ASSOCIATION_COPY) }
    }

    /// Has the shell reach the machine the way the machine says: over TCP, or
    /// through a Cloudflare tunnel to its address.
    internal func applyTransport(for machine: RDMachine) {
        tunnelFailure = nil
        switch machine.transport {
        case .direct:
            setupConnectionSocketProvider(nil)
        case .cloudflareAccess:
            let id = machine.cloudflareServiceTokenID
            let secret = machine.cloudflareServiceTokenSecret
            setupConnectionSocketProvider { [weak self] host, _, timeout in
                switch CloudflareAccessTunnel.open(
                    hostname: host,
                    serviceTokenID: id,
                    serviceTokenSecret: secret,
                    timeout: max(timeout.doubleValue, 10)
                ) {
                case let .success(fd):
                    self?.tunnelFailure = nil
                    return fd
                case let .failure(failure):
                    self?.tunnelFailure = failure.message
                    return -1
                }
            }
        }
    }
}
