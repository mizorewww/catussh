//
//  IdentityDraft.swift
//  CatusshModule
//
//  Shared identity validation and draft state across macOS and iOS.
//

import Foundation

public extension RDIdentity {
    /// An OpenSSH public key starts with its algorithm — and ecdsa-sha2-* and the
    /// FIDO sk-* types contain no "ssh-" for a substring check to find.
    static func looksLikePublicKey(_ string: String) -> Bool {
        let prefixes = ["ssh-rsa", "ssh-ed25519", "ecdsa-sha2-", "sk-ssh-", "sk-ecdsa-"]
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    static func looksLikePrivateKey(_ string: String) -> Bool {
        string.contains("PRIVATE KEY")
    }
}

/// Editable copy of an identity.
public struct IdentityDraft: Equatable, Sendable {
    public enum Method: Hashable, Sendable {
        case keyPair
        case password
    }

    public var username = ""
    public var group = ""
    public var method: Method = .password
    public var password = ""
    public var passphrase = ""
    public var privateKey = ""
    public var publicKey = ""
    public var comment = ""
    public var automatic = true

    public init() {}

    public init(_ identity: RDIdentity) {
        username = identity.username
        group = identity.group
        if identity.privateKey.isEmpty {
            method = .password
            password = identity.password
            passphrase = ""
        } else {
            method = .keyPair
            password = ""
            passphrase = identity.password
        }
        privateKey = identity.privateKey
        publicKey = identity.publicKey
        comment = identity.comment
        automatic = identity.authenticAutomatically
    }

    public var isValid: Bool {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch method {
        case .password:
            return !password.isEmpty
        case .keyPair:
            return !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func apply(to identity: RDIdentity) -> RDIdentity {
        var result = identity
        result.username = username.trimmingCharacters(in: .whitespaces)
        result.group = group
        result.password = method == .keyPair ? passphrase : password
        result.privateKey = method == .keyPair ? privateKey : ""
        result.publicKey = method == .keyPair ? publicKey : ""
        result.comment = comment
        result.authenticAutomatically = automatic
        return result
    }

    public func differs(from identity: RDIdentity) -> Bool {
        let originalMethod: Method = identity.privateKey.isEmpty ? .password : .keyPair
        if method != originalMethod { return true }
        let edited = apply(to: identity)
        return edited.username != identity.username
            || edited.group != identity.group
            || edited.password != identity.password
            || edited.privateKey != identity.privateKey
            || edited.publicKey != identity.publicKey
            || edited.comment != identity.comment
            || edited.authenticAutomatically != identity.authenticAutomatically
    }
}
