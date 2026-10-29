//
//  RDMachine+RemoteDesktop.swift
//  CatusshModule
//
//  Remote desktop settings for a server: which protocol (if any) draws its
//  screen, plus per-protocol fields. Everything lives in `attachment`, so
//  servers saved before this read as "no remote desktop" and sync carries
//  the fields with the server.
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

    var remoteDesktopProtocol: RemoteDesktopProtocolType {
        get { attachment["remoteDesktop.protocol"].flatMap(RemoteDesktopProtocolType.init(rawValue:)) ?? .none }
        set { attachment["remoteDesktop.protocol"] = newValue == .none ? nil : newValue.rawValue }
    }

    /// True when the server is configured for a graphical session.
    var hasRemoteDesktop: Bool {
        remoteDesktopProtocol != .none
    }

    /// A device on a UU Remote account, reached through UU Remote alone:
    /// no SSH address, so SSH tools do not apply.
    var isUURemoteDevice: Bool {
        // An SSH server may show its desktop through UU Remote; it is still
        // an SSH server.
        remoteDesktopProtocol == .uuRemote && transport == .uuRemote && !uuDeviceID.isEmpty
    }

    // MARK: - VNC

    /// The port the VNC server listens on, on `remoteAddress`.
    var vncPort: String {
        get { attachment["remoteDesktop.vnc.port", default: "5900"] }
        set { attachment["remoteDesktop.vnc.port"] = newValue.isEmpty || newValue == "5900" ? nil : newValue }
    }

    /// The VNC password. Empty falls back to the associated identity's
    /// password; many VNC servers share the login password.
    var vncPassword: String {
        get { attachment["remoteDesktop.vnc.password", default: ""] }
        set { attachment["remoteDesktop.vnc.password"] = newValue.isEmpty ? nil : newValue }
    }

    /// The account for Apple Remote Desktop authentication (macOS Screen
    /// Sharing). Empty falls back to the associated identity's user name,
    /// but only when the password comes from the identity too.
    var vncUsername: String {
        get { attachment["remoteDesktop.vnc.username", default: ""] }
        set { attachment["remoteDesktop.vnc.username"] = newValue.isEmpty ? nil : newValue }
    }

    /// The `shared` flag of the RFB ClientInit message: true keeps other
    /// viewers attached instead of disconnecting them.
    var vncShared: Bool {
        get { attachment["remoteDesktop.vnc.shared"] != "0" }
        set { attachment["remoteDesktop.vnc.shared"] = newValue ? nil : "0" }
    }

    /// True reaches the VNC server through an SSH local port forward
    /// (`ssh -L`), so a VNC port that only listens on the remote loopback
    /// still works.
    var vncOverSSH: Bool {
        get { attachment["remoteDesktop.vnc.overSSH"] == "1" }
        set { attachment["remoteDesktop.vnc.overSSH"] = newValue ? "1" : nil }
    }

    /// The effective VNC password: the stored one, else the associated
    /// identity's password. Read on the main thread.
    func resolvedVNCPassword(in store: CatusshStore) -> String {
        resolvedVNCPassword(identity: associatedIdentity.flatMap { UUID(uuidString: $0) }.map { store.identityGroup[$0] })
    }

    /// The effective VNC password for a pre-resolved identity, safe to call
    /// off the main thread with the store's worker snapshot.
    func resolvedVNCPassword(identity: RDIdentity?) -> String {
        if !vncPassword.isEmpty { return vncPassword }
        return identity?.password ?? ""
    }

    /// The effective Apple Remote Desktop user name: the stored one, else the
    /// associated identity's when its password is the one used. A stored VNC
    /// password is a VNC password ("VNC viewers may control screen with
    /// password" on a Mac), so it is not paired with the identity's name and
    /// the Mac is reached with VNC authentication. Only used when the server
    /// offers Apple authentication.
    func resolvedVNCUsername(identity: RDIdentity?) -> String {
        if !vncUsername.isEmpty { return vncUsername }
        guard vncPassword.isEmpty else { return "" }
        return identity?.username ?? ""
    }

    // MARK: - NetEase UU Remote

    /// The bound UU Remote device identifier (`anonymous_device_id`-style
    /// encrypted id, or a plain device id from the account's device list).
    var uuDeviceID: String {
        get { attachment["remoteDesktop.uu.deviceID", default: ""] }
        set { attachment["remoteDesktop.uu.deviceID"] = newValue.isEmpty ? nil : newValue }
    }

    /// Display name of the bound device, kept for lists when the device list
    /// is unavailable.
    var uuDeviceAlias: String {
        get { attachment["remoteDesktop.uu.deviceAlias", default: ""] }
        set { attachment["remoteDesktop.uu.deviceAlias"] = newValue.isEmpty ? nil : newValue }
    }

    /// The encrypted `anonymous_device_id` the official UU Remote app
    /// hands back through its authorize callback; lets the
    /// `uuremote://external/device/control` PiP handoff skip re-auth.
    var uuAnonymousDeviceID: String {
        get { attachment["remoteDesktop.uu.anonymousDeviceID", default: ""] }
        set { attachment["remoteDesktop.uu.anonymousDeviceID"] = newValue.isEmpty ? nil : newValue }
    }

    /// Remote-assistance connect id, for sessions that join by code rather
    /// than by account device.
    var uuAssistID: String {
        get { attachment["remoteDesktop.uu.assistID", default: ""] }
        set { attachment["remoteDesktop.uu.assistID"] = newValue.isEmpty ? nil : newValue }
    }

    /// Remote-assistance verification code paired with `uuAssistID`.
    var uuAssistCode: String {
        get { attachment["remoteDesktop.uu.assistCode", default: ""] }
        set { attachment["remoteDesktop.uu.assistCode"] = newValue.isEmpty ? nil : newValue }
    }

    /// Which of the host's displays to open; 0 is the primary display.
    var uuDisplayID: Int {
        get { attachment["remoteDesktop.uu.displayID"].flatMap(Int.init) ?? 0 }
        set { attachment["remoteDesktop.uu.displayID"] = newValue == 0 ? nil : String(newValue) }
    }

    /// Requested frame rate tier: 30 / 60 / 90 / 144.
    var uuFPS: Int {
        get { attachment["remoteDesktop.uu.fps"].flatMap(Int.init) ?? 60 }
        set { attachment["remoteDesktop.uu.fps"] = newValue == 60 ? nil : String(newValue) }
    }

    /// Requested quality tier (the protocol's video_quality values).
    var uuQuality: Int {
        get { attachment["remoteDesktop.uu.quality"].flatMap(Int.init) ?? 5 }
        set { attachment["remoteDesktop.uu.quality"] = newValue == 5 ? nil : String(newValue) }
    }
}
