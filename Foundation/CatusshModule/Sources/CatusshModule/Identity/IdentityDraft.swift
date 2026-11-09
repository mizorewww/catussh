//
//  IdentityDraft.swift
//  CatusshModule
//
//  Shared identity validation and draft state across macOS and iOS.
//

import CryptoKit
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

    /// Generates a new OpenSSH Ed25519 key pair in memory using CryptoKit.
    static func generateEd25519KeyPair(comment: String = "catussh") -> (privateKey: String, publicKey: String) {
        let signingKey = Curve25519.Signing.PrivateKey()
        let rawSeed = signingKey.rawRepresentation
        let rawPub = signingKey.publicKey.rawRepresentation

        func sshBytes(_ data: Data) -> Data {
            var out = Data()
            var len = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(data)
            return out
        }
        func sshString(_ str: String) -> Data { sshBytes(Data(str.utf8)) }
        func sshUInt32(_ val: UInt32) -> Data {
            var out = Data()
            var be = val.bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            return out
        }

        let keyType = "ssh-ed25519"
        var pubBlob = Data()
        pubBlob.append(sshString(keyType))
        pubBlob.append(sshBytes(rawPub))

        let cleanComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveComment = cleanComment.isEmpty ? "catussh" : cleanComment
        let publicKeyString = "\(keyType) \(pubBlob.base64EncodedString()) \(effectiveComment)"

        var privSection = Data()
        let checkInt = UInt32.random(in: 0 ... UInt32.max)
        privSection.append(sshUInt32(checkInt))
        privSection.append(sshUInt32(checkInt))
        privSection.append(sshString(keyType))
        privSection.append(sshBytes(rawPub))
        var secret64 = Data()
        secret64.append(rawSeed)
        secret64.append(rawPub)
        privSection.append(sshBytes(secret64))
        privSection.append(sshString(effectiveComment))

        var padByte: UInt8 = 1
        while privSection.count % 8 != 0 {
            privSection.append(padByte)
            padByte &+= 1
        }

        var fullBlob = Data("openssh-key-v1\0".utf8)
        fullBlob.append(sshString("none"))
        fullBlob.append(sshString("none"))
        fullBlob.append(sshBytes(Data()))
        fullBlob.append(sshUInt32(1))
        fullBlob.append(sshBytes(pubBlob))
        fullBlob.append(sshBytes(privSection))

        let b64 = fullBlob.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let privateKeyString = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(b64)\n-----END OPENSSH PRIVATE KEY-----\n"
        return (privateKeyString, publicKeyString)
    }
}

/// Editable copy of an identity.
public struct IdentityDraft: Equatable, Sendable {
    public enum Method: Hashable, Sendable {
        case keyPair
        case password
        case sshAgent
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
        if identity.useSSHAgent {
            method = .sshAgent
            password = ""
            passphrase = ""
        } else if identity.privateKey.isEmpty {
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
        case .sshAgent:
            return true
        }
    }

    public func apply(to identity: RDIdentity) -> RDIdentity {
        var result = identity
        result.username = username.trimmingCharacters(in: .whitespaces)
        result.group = group
        result.useSSHAgent = (method == .sshAgent)
        switch method {
        case .keyPair:
            result.password = passphrase
            result.privateKey = privateKey
            result.publicKey = publicKey
        case .password:
            result.password = password
            result.privateKey = ""
            result.publicKey = ""
        case .sshAgent:
            result.password = ""
            result.privateKey = ""
            result.publicKey = ""
        }
        result.comment = comment
        result.authenticAutomatically = automatic
        return result
    }

    public func differs(from identity: RDIdentity) -> Bool {
        let originalMethod: Method = identity.useSSHAgent ? .sshAgent : (identity.privateKey.isEmpty ? .password : .keyPair)
        if method != originalMethod { return true }
        let edited = apply(to: identity)
        return edited.username != identity.username
            || edited.group != identity.group
            || edited.password != identity.password
            || edited.privateKey != identity.privateKey
            || edited.publicKey != identity.publicKey
            || edited.useSSHAgent != identity.useSSHAgent
            || edited.comment != identity.comment
            || edited.authenticAutomatically != identity.authenticAutomatically
    }
}
