//
//  RDMachine+RemoteDesktop.swift
//  CatusshModule
//
//  Remote desktop settings for a server: which protocol (if any) draws its
//  screen, plus per-protocol helpers.
//

import Foundation

public extension RDMachine {
    /// How a graphical session on the server is rendered.
    enum RemoteDesktopProtocolType: String, CaseIterable, Codable, Sendable {
        /// The server offers no graphical session; the tool is hidden.
        case none
        /// A VNC server speaking RFB 3.3 / 3.7 / 3.8, on `remoteAddress:vncPort`.
        case vnc
        /// A NetEase UU Remote host, reached through its cloud service.
        case uuRemote = "uu-remote"
    }

    /// True when the server is configured for a graphical session.
    var hasRemoteDesktop: Bool {
        remoteDesktopProtocol != .none
    }

    /// A device on a UU Remote account, reached through UU Remote alone:
    /// no SSH address, so SSH tools do not apply.
    var isUURemoteDevice: Bool {
        remoteDesktopProtocol == .uuRemote && transport == .uuRemote && !uuDeviceID.isEmpty
    }

    /// The effective VNC password: the stored one, else the associated
    /// identity's password. Read on the main thread.
    func resolvedVNCPassword(in store: CatusshStore) -> String {
        resolvedVNCPassword(identity: associatedIdentity.flatMap { UUID(uuidString: $0) }.flatMap { store.identityGroup.find($0) })
    }

    /// The effective VNC password for a pre-resolved identity, safe to call
    /// off the main thread with the store's worker snapshot.
    func resolvedVNCPassword(identity: RDIdentity?) -> String {
        if !vncPassword.isEmpty { return vncPassword }
        return identity?.password ?? ""
    }

    /// The effective Apple Remote Desktop user name: the stored one, else the
    /// associated identity's when its password is the one used.
    func resolvedVNCUsername(identity: RDIdentity?) -> String {
        if !vncUsername.isEmpty { return vncUsername }
        guard vncPassword.isEmpty else { return "" }
        return identity?.username ?? ""
    }
}
