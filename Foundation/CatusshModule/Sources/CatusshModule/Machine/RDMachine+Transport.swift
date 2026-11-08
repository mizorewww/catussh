//
//  RDMachine+Transport.swift
//  CatusshModule
//
//  How a server is reached: straight over TCP, through Cloudflare Access,
//  or through a NetEase UU Remote port-mapping stream.
//

import Foundation

public extension RDMachine {
    enum Transport: String, CaseIterable, Codable, Sendable {
        /// A TCP connection to the address and port.
        case direct
        /// A WebSocket to `https://<address>` that Cloudflare's edge relays to
        /// the SSH server behind a Cloudflare Tunnel. The port only names the
        /// host key.
        case cloudflareAccess = "cloudflare-access"
        /// A NetEase UU Remote port-mapping stream to `remoteAddress:remotePort`,
        /// carried on the FILE_DATA_CHANNEL of an active UU session.
        case uuRemote = "uu-remote"
    }
}
