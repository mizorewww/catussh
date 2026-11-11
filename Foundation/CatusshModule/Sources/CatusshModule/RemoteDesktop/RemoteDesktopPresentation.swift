//
//  RemoteDesktopPresentation.swift
//  CatusshModule
//
//  How the Remote Desktop pages of both apps name a desktop and its state:
//  the target line under a server, and a session's phase as a dot and a word.
//

import CatusshDesign
import Foundation

public extension RDMachine {
    /// "VNC · host:5900 · over SSH" or "UU Remote · device · Online".
    /// `uuDevice` is the account's listing of the device, when known.
    func remoteDesktopTarget(uuDevice: UUDeviceInfo?) -> String {
        switch remoteDesktopProtocol {
        case .vnc:
            var parts = ["VNC", remoteAddress + ":" + vncPort]
            if vncOverSSH { parts.append("over SSH") }
            return parts.joined(separator: " · ")
        case .uuRemote:
            var parts = ["UU Remote"]
            // The device's name only when the server's says something else.
            let alias = uuDeviceAlias
            if !alias.isEmpty, alias != name { parts.append(alias) }
            if let uuDevice { parts.append(uuDevice.isOnline ? "Online" : "Offline") }
            return parts.joined(separator: " · ")
        case .none:
            return ""
        }
    }
}

public extension RemoteDesktopSession {
    /// The phase as a status dot.
    var phaseStatus: RXStatus {
        switch phase {
        case .connected: .success
        case .idle: .off
        case .connecting, .authenticating: .running
        case .closed: .warning
        case .failed: .danger
        }
    }

    /// The phase in a word.
    var phaseTitle: String {
        switch phase {
        case .connected: viewOnly ? "Viewing" : "Connected"
        case .idle: "Idle"
        case .connecting, .authenticating: "Connecting"
        case .closed: "Closed"
        case .failed: "Failed"
        }
    }
}
