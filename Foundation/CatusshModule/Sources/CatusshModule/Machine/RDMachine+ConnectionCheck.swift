//
//  RDMachine+ConnectionCheck.swift
//  CatusshModule
//
//  "Add and Connect": before a new server is saved, connect to it and find
//  an identity that signs in. Shared by the macOS and iOS server editors.
//

import Foundation
import NSRemoteShell

public enum ServerConnectionCheck {
    public enum Outcome: Sendable {
        /// Signed in with this identity; the banner the server sent.
        case authenticated(identity: RDIdentity.ID, banner: String)
        /// The server could not be reached; why, when known.
        case unreachable(reason: String?)
        /// Reached, but no identity tried could sign in.
        case rejected
    }

    /// Connects to `draft` and signs in with `identity`, or else with each
    /// identity that authenticates automatically. Blocks; call off the main
    /// thread.
    public static func run(
        _ draft: RDMachine,
        identity chosen: RDIdentity?,
        candidates: [RDIdentity],
        timeout: NSNumber
    ) -> Outcome {
        let shell = NSRemoteShell.configured(for: draft, timeout: timeout)
        shell.requestConnectAndWait()
        guard shell.isConnected else {
            return .unreachable(reason: shell.connectFailureReason)
        }
        var authenticatedWith: RDIdentity.ID?
        if let chosen {
            chosen.callAuthenticationWith(remote: shell)
            if shell.isAuthenticated { authenticatedWith = chosen.id }
        } else {
            for candidate in candidates {
                if shell.isAuthenticated { break }
                if !shell.isConnected { shell.requestConnectAndWait() }
                candidate.callAuthenticationWith(remote: shell)
                if shell.isAuthenticated { authenticatedWith = candidate.id }
            }
        }
        let banner = shell.remoteBanner ?? ""
        shell.requestDisconnectAndWait()
        guard let authenticatedWith else { return .rejected }
        return .authenticated(identity: authenticatedWith, banner: banner)
    }
}
