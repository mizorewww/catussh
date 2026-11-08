//
//  RDIdentity.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/9.
//

import Foundation
import NSRemoteShell

public struct RDIdentity: Codable, Identifiable, Equatable, Sendable {
    public init(
        id: UUID = .init(),
        username: String = "",
        password: String = "",
        privateKey: String = "",
        publicKey: String = "",
        lastRecentUsed: Date = .init(),
        comment: String = "",
        group: String = "",
        authenticAutomatically: Bool = true,
        attachment: [String: String] = [:]
    ) {
        self.id = id
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.lastRecentUsed = lastRecentUsed
        self.comment = comment
        self.group = group
        self.authenticAutomatically = authenticAutomatically
        self.attachment = attachment
    }

    public var id = UUID()

    // generic authenticate filed required for ssh
    public var username: String
    public var password: String
    public var privateKey: String
    public var publicKey: String

    // application required
    public var lastRecentUsed: Date
    public var comment: String
    public var group: String
    public var authenticAutomatically: Bool

    // reserved for future use
    public var attachment: [String: String]

    public func shortDescription() -> String {
        guard username.count > 0 else {
            return "Unknown Error"
        }
        var build = "User \(username) with \(getKeyType())"
        if group.count > 0 {
            build += " Group<\(group)>"
        }
        if comment.count > 0 {
            build += " (\(comment))"
        }
        return build
    }

    public func getKeyType() -> String {
        if privateKey.count > 0, publicKey.count > 0 {
            if password.count > 0 {
                return "Key Pair"
            } else {
                return "Plain Key Pair"
            }
        } else if privateKey.count > 0 {
            if password.count > 0 {
                return "Private Key"
            } else {
                return "Plain Private Key"
            }
        } else if publicKey.count > 0 {
            return "Unknown Key"
        } else if password.count > 0 {
            return "Password"
        } else {
            return "Username Only"
        }
    }

    public func callAuthenticationWith(remote: NSRemoteShell) {
        if remote.isAuthenticated { return }
        if privateKey.count > 0 || publicKey.count > 0 {
            remote.authenticate(with: username, andPublicKey: publicKey, andPrivateKey: privateKey, andPassword: password)
        } else {
            remote.authenticate(with: username, andPassword: password)
        }
        guard remote.isAuthenticated else {
            return
        }
        let date = Date()
        debugPrint("Identity \(id) was used to authenticate session at \(date.ISO8601Format())")
        onMainThread {
            if var existing = CatusshStore.shared.identityGroup.find(id),
               abs(existing.lastRecentUsed.timeIntervalSince(date)) > 60
            {
                existing.lastRecentUsed = date
                CatusshStore.shared.identityGroup[id] = existing
            }
        }
    }
}

public extension RDIdentity {
    /// "Key pair · ed25519", "Password" style description.
    var authDescription: String {
        if !privateKey.isEmpty {
            if let type = keyAlgorithm { return "Key pair · \(type)" }
            return "Key pair"
        }
        if !password.isEmpty { return "Password" }
        return "No credentials"
    }

    var keyAlgorithm: String? {
        let source = publicKey.isEmpty ? privateKey : publicKey
        for (marker, name) in [("ssh-ed25519", "ed25519"), ("ecdsa-sha2", "ecdsa"), ("ssh-rsa", "rsa"), ("BEGIN RSA", "rsa"), ("BEGIN EC", "ecdsa")] {
            if source.contains(marker) { return name }
        }
        return nil
    }
}

extension RDIdentity: RDGroupItem {
    public init() { self.init(id: UUID()) }
}
