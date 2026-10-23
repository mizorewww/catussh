//
//  RDMachine+Transport.swift
//  CatusshModule
//
//  How a server is reached: straight over TCP, or through Cloudflare Access,
//  which is what `ssh -o ProxyCommand='cloudflared access ssh --hostname %h'`
//  does. Kept in `attachment`, so servers saved before this read as direct and
//  sync carries the setting with the server.
//

import Foundation

public extension RDMachine {
    enum Transport: String, CaseIterable, Sendable {
        /// A TCP connection to the address and port.
        case direct
        /// A WebSocket to `https://<address>` that Cloudflare's edge relays to
        /// the SSH server behind a Cloudflare Tunnel. The port only names the
        /// host key.
        case cloudflareAccess = "cloudflare-access"
    }

    var transport: Transport {
        get { attachment["transport"].flatMap(Transport.init(rawValue:)) ?? .direct }
        set { attachment["transport"] = newValue == .direct ? nil : newValue.rawValue }
    }

    /// The Client ID of a Cloudflare Access service token, for an application
    /// whose policy asks for one. Empty when the application needs none.
    var cloudflareServiceTokenID: String {
        get { attachment["cloudflare.serviceToken.id", default: ""] }
        set { attachment["cloudflare.serviceToken.id"] = newValue.isEmpty ? nil : newValue }
    }

    /// The Client Secret of that service token. Kept with the server, which is
    /// stored encrypted like an identity's password.
    var cloudflareServiceTokenSecret: String {
        get { attachment["cloudflare.serviceToken.secret", default: ""] }
        set { attachment["cloudflare.serviceToken.secret"] = newValue.isEmpty ? nil : newValue }
    }
}
