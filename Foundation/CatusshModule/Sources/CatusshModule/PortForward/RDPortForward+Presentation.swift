//
//  RDPortForward+Presentation.swift
//  CatusshModule
//
//  The words a forward is shown with: its kind, its target and the ssh
//  command it stands for, complete or not. Shared by the macOS and iOS
//  lists and editors.
//

import Foundation

public extension RDPortForward.ForwardOrientation {
    /// The kind, as a row's tag.
    var label: String {
        switch self {
        case .listenLocal: return "Listen local"
        case .listenRemote: return "Listen remote"
        case .dynamicSOCKS: return "SOCKS5 (-D)"
        }
    }

    /// Where traffic goes, from `device` ("This Mac", "This iPhone").
    func flowDescription(device: String) -> String {
        switch self {
        case .listenLocal: return "\(device) :port → server → target"
        case .listenRemote: return "Server :port → \(device.prefix(1).lowercased() + device.dropFirst()) → target"
        case .dynamicSOCKS: return "\(device) :port (SOCKS5) → server → any destination"
        }
    }
}

public extension RDPortForward {
    /// host:port, or what a SOCKS proxy reaches instead.
    var targetLabel: String {
        if forwardOrientation == .dynamicSOCKS { return "SOCKS5 proxy" }
        return targetHost.isEmpty ? "—" : "\(targetHost):\(targetPort)"
    }

    /// The equivalent ssh command; while the forward is incomplete, the
    /// command with placeholders for what is missing.
    var commandPreview: String {
        if let command = getCommand() { return command }
        let bind = bindPort > 0 ? String(bindPort) : ""
        switch forwardOrientation {
        case .dynamicSOCKS:
            return "ssh -D \(bind.isEmpty ? "1080" : bind) <server>"
        case .listenLocal, .listenRemote:
            let flag = forwardOrientation == .listenLocal ? "-L" : "-R"
            let target = targetPort > 0 ? String(targetPort) : ""
            return "ssh \(flag) \(bind.isEmpty ? "port" : bind):\(targetHost.isEmpty ? "127.0.0.1" : targetHost):\(target.isEmpty ? "port" : target) <server>"
        }
    }
}
