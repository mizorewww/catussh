//
//  VNCSSHTunnel.swift
//  CatusshModule
//
//  `vncOverSSH`: an SSH local port forward — `ssh -L <port>:127.0.0.1:<vnc>`
//  — over its own NSRemoteShell, so the VNC stream to a remote loopback
//  VNC server still works. Runs its own thread; `start` waits until the
//  local listener is accepting and hands back the local port.
//

import Darwin
import Foundation
import NSRemoteShell

final class VNCSSHTunnel: @unchecked Sendable {
    private let machine: RDMachine
    private let targetPort: UInt16
    private var shell: NSRemoteShell?
    private var worker: Thread?
    private let ready = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var listenerPort: UInt16 = 0
    private var failure: String?
    private var finished = false
    /// `stop` is a separate latch from `finished`: `run` marks `finished`
    /// once setup ends (success or failure), but the forward keeps running
    /// until someone actually disconnects the shell.
    private var stopped = false
    /// `ready` fires exactly once: either the forward's completion handler
    /// reports the listener bound, or `finish` reports a failure. Signalling
    /// on the success path of `finish` would race `createPortForward`.
    private var readySignaled = false

    init(machine: RDMachine, targetPort: UInt16) {
        self.machine = machine
        self.targetPort = targetPort
    }

    /// Opens the SSH session and the local forward; returns the local port
    /// to dial, or the failure to show.
    func start() -> Result<UInt16, RemoteDesktopFailure> {
        let thread = Thread { [self] in run() }
        thread.name = "me.mizorewww.vnc-ssh-tunnel.\(machine.remoteAddress)"
        thread.start()
        worker = thread
        guard ready.wait(timeout: .now() + 30) == .success else {
            stop()
            return .failure(RemoteDesktopFailure("Timed out opening the SSH tunnel."))
        }
        return stateLock.withLock {
            if let failure { .failure(RemoteDesktopFailure(failure)) } else { .success(listenerPort) }
        }
    }

    /// Stops forwarding and tears the SSH session down. Works even after
    /// `run` finished — the forward listener and shell still need closing.
    func stop() {
        let shell = stateLock.withLock { () -> NSRemoteShell? in
            guard !stopped else { return nil }
            stopped = true
            return self.shell
        }
        DispatchQueue.global().async { [weak shell] in
            shell?.requestDisconnectAndWait()
            shell?.destroyPermanently()
        }
    }

    /// A free local TCP port to bind the forward listener to.
    private func pickLocalPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &resolved, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }) == 0 else { return nil }
        return UInt16(bigEndian: resolved.sin_port)
    }

    private func run() {
        guard let localPort = pickLocalPort() else {
            finish(failure: "Could not allocate a local port for the SSH tunnel.")
            return
        }
        stateLock.withLock { listenerPort = localPort }

        let shell = NSRemoteShell()
        let proceed = stateLock.withLock { () -> Bool in
            guard !stopped else { return false }
            self.shell = shell
            return true
        }
        guard proceed else {
            // `stop` ran before the shell existed; do not let it leak.
            shell.requestDisconnectAndWait()
            shell.destroyPermanently()
            return
        }
        shell.applyConnection(for: machine, timeout: CatusshStore.shared.workerTimeoutNumber)
        let result = shell.connectAndAuthenticate(
            identity: CatusshStore.shared.workerAssociatedIdentity(for: machine),
            autoIdentities: CatusshStore.shared.workerIdentitiesForAutoAuth
        )
        guard result == .success else {
            let reason = result == .connectFailed
                ? (shell.connectFailureReason ?? "Could not connect for the SSH tunnel.")
                : "SSH authentication failed for the tunnel."
            finish(failure: reason)
            return
        }
        shell.createPortForward(
            withLocalPort: NSNumber(value: localPort),
            withForwardTargetHost: "127.0.0.1",
            withForwardTargetPort: NSNumber(value: targetPort)
        ) { [weak self] in
            // The listener is bound and accepting; the client may dial.
            self?.signalReady()
        } withContinuationHandler: {
            true // the forward runs until the shell disconnects
        }
        finish(failure: nil)
    }

    private func finish(failure: String?) {
        let shouldSignal = stateLock.withLock { () -> Bool in
            if let failure { self.failure = failure }
            finished = true
            // Success leaves the signal to the port-forward completion
            // handler: it fires when the listener is actually bound.
            guard failure != nil, !readySignaled else { return false }
            readySignaled = true
            return true
        }
        if shouldSignal { ready.signal() }
    }

    private func signalReady() {
        let shouldSignal = stateLock.withLock { () -> Bool in
            guard !readySignaled else { return false }
            readySignaled = true
            return true
        }
        if shouldSignal { ready.signal() }
    }
}
