//
//  NSRemoteShell+catussh.swift
//  CatusshModule
//
//  Shared shell scaffolding, previously copy-pasted across both apps.
//

import Foundation
import NSRemoteShell

public extension NSRemoteShell {
    /// Returns a shell preconfigured with the machine's address and port.
    /// An unparsable port keeps the historical 0 value, which simply fails
    /// to connect and surfaces through the usual error path.
    @discardableResult
    static func configured(for machine: RDMachine, timeout: NSNumber) -> NSRemoteShell {
        NSRemoteShell().applyConnection(for: machine, timeout: timeout)
    }

    /// Returns a shell preconfigured with the given address and port string.
    @discardableResult
    static func configured(host: String, port: String, timeout: NSNumber) -> NSRemoteShell {
        NSRemoteShell().applyConnection(host: host, port: port, timeout: timeout)
    }

    /// Applies connection parameters to an existing shell, returning self for
    /// chaining. The shell connects over TCP.
    @discardableResult
    func applyConnection(host: String, port: String, timeout: NSNumber) -> NSRemoteShell {
        applyConnection(for: RDMachine(remoteAddress: host, remotePort: port), timeout: timeout)
    }

    /// Applies the machine's connection parameters to an existing shell,
    /// including how it is reached (TCP or a Cloudflare tunnel).
    @discardableResult
    func applyConnection(for machine: RDMachine, timeout: NSNumber) -> NSRemoteShell {
        KnownHosts.install()
        applyTransport(for: machine)
        return setupConnectionHost(machine.remoteAddress)
            .setupConnectionPort(NSNumber(value: Int(machine.remotePort) ?? 0))
            .setupConnectionTimeout(timeout)
    }

    /// Why the last connection failed, for the person: the host key refused,
    /// a tunnel could not be opened, or nil when it was just unreachable.
    var connectFailureReason: String? {
        hostKeyRefusal ?? tunnelFailure ?? uuTunnelFailure
    }

    /// Tries each identity in order, reconnecting when the username changes
    /// (the remote side authenticates per connection, so a new username needs
    /// a fresh connection). Returns true when the shell ends up authenticated.
    @discardableResult
    func authenticateWithAutoIdentities(
        _ identities: [RDIdentity],
        hint: ((String) -> Void)? = nil
    ) -> Bool {
        var previousUsername: String?
        for identity in identities {
            hint?("[i] trying to authenticate with \(identity.shortDescription())")
            if let prev = previousUsername, prev != identity.username {
                requestDisconnectAndWait()
                requestConnectAndWait()
            }
            previousUsername = identity.username
            identity.callAuthenticationWith(remote: self)
            if isConnected, isAuthenticated {
                break
            }
        }
        return isConnected && isAuthenticated
    }

    /// Outcome of `connectAndAuthenticate`.
    enum ConnectAndAuthenticateResult {
        /// Connected and authenticated.
        case success
        /// The initial connection failed.
        case connectFailed
        /// Connected, but authentication failed.
        case authenticateFailed
    }

    /// Connects (blocking), then authenticates with `identity` when given,
    /// otherwise with each of `autoIdentities` in turn. Shared by the
    /// terminal, file-transfer and monitor bootstraps of both apps.
    @discardableResult
    func connectAndAuthenticate(
        identity: RDIdentity?,
        autoIdentities: [RDIdentity],
        hint: ((String) -> Void)? = nil
    ) -> ConnectAndAuthenticateResult {
        KnownHosts.install()
        requestConnectAndWait()
        guard isConnected else { return .connectFailed }
        if let identity {
            identity.callAuthenticationWith(remote: self)
        } else {
            authenticateWithAutoIdentities(autoIdentities, hint: hint)
        }
        return isConnected && isAuthenticated ? .success : .authenticateFailed
    }
}
