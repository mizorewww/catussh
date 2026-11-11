//
//  SyncCipher.swift
//  CatusshModule
//
//  What iCloud holds is sealed on the device: AES-256-GCM under a random key
//  kept in iCloud Keychain (end-to-end encrypted, so it reaches the user's
//  other devices and no one else), or, where there is no iCloud Keychain,
//  under a key that only a passphrase gives (PBKDF2-HMAC-SHA256). Apple stores
//  bytes it cannot read.
//

import CommonCrypto
import CryptoKit
import Foundation

/// The stored form: which key sealed it, and the sealed document.
///
/// Version 1 was always sealed under a passphrase and has only `salt` and
/// `rounds`; it is still read. Version 2 says which kind of key sealed it.
struct SyncEnvelope: Codable {
    static let currentVersion = 2

    enum Sealer: String, Codable {
        /// The random key in iCloud Keychain named by `keyID`.
        case keychain
        /// A key derived from a passphrase with `salt` and `rounds`.
        case passphrase
    }

    var version = SyncEnvelope.currentVersion
    /// Absent in version 1, which is always `.passphrase`.
    var sealer: Sealer?
    var keyID: String?
    var salt: Data?
    var rounds: Int?
    /// Nonce, ciphertext and tag.
    var sealed: Data

    var kind: Sealer { version < 2 ? .passphrase : sealer ?? .passphrase }
}

/// A random key, kept in iCloud Keychain under its id. The id is worked out
/// from the key, so two devices never give one id to two keys.
struct SyncKey: Sendable {
    let id: String
    let key: SymmetricKey

    init(data: Data) {
        key = SymmetricKey(data: data)
        id = Self.identifier(of: data)
    }

    static func generate() -> SyncKey {
        SyncKey(data: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    var data: Data { key.withUnsafeBytes { Data($0) } }

    private static func identifier(of data: Data) -> String {
        let hash = SHA256.hash(data: Data("me.mizorewww.rayon.sync.key-id".utf8) + data)
        return hash.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

enum SyncCipher {
    /// Why an envelope did not open.
    enum OpenError: Error {
        /// The key does not fit: the passphrase is wrong.
        case wrongPassphrase
        /// It opened, but what is inside is damaged.
        case corruptedData
    }

    /// A key, and the salt and rounds it came from.
    struct Key: Sendable {
        let salt: Data
        let rounds: Int
        let key: SymmetricKey
    }

    /// What to seal under.
    enum Sealing: Sendable {
        case keychain(SyncKey)
        case passphrase(Key)
    }

    static let rounds = 600_000
    /// Fewer rounds than this are refused: whoever can write to the store
    /// could otherwise have the next upload sealed under a weak key.
    static let minimumRounds = 100_000
    static let maximumRounds = 10_000_000

    /// Authenticated with what is sealed, so the header cannot be swapped.
    static let context = Data("me.mizorewww.rayon.sync.v1".utf8)

    static func context(for envelope: SyncEnvelope) -> Data {
        guard envelope.version >= 2 else { return context }
        var text = "me.mizorewww.rayon.sync.v2.\(envelope.kind.rawValue)"
        if let id = envelope.keyID { text += "." + id }
        return Data(text.utf8)
    }

    static func newSalt() -> Data {
        Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func key(passphrase: String, salt: Data, rounds: Int) -> Key {
        var derived = [UInt8](repeating: 0, count: 32)
        let password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        let status = salt.withUnsafeBytes { saltBytes in
            password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: CChar.self).baseAddress, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(rounds),
                    &derived, derived.count
                )
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 takes any password and salt")
        return Key(salt: salt, rounds: rounds, key: SymmetricKey(data: derived))
    }

    static func seal(_ plain: Data, with key: Key) throws -> Data {
        try seal(plain, with: .passphrase(key))
    }

    static func seal(_ plain: Data, with sealing: Sealing) throws -> Data {
        var envelope = SyncEnvelope(sealed: Data())
        let symmetric: SymmetricKey
        switch sealing {
        case let .keychain(key):
            envelope.sealer = .keychain
            envelope.keyID = key.id
            symmetric = key.key
        case let .passphrase(key):
            envelope.sealer = .passphrase
            envelope.salt = key.salt
            envelope.rounds = key.rounds
            symmetric = key.key
        }
        let packed = try (plain as NSData).compressed(using: .zlib) as Data
        let box = try CryptoKit.AES.GCM.seal(packed, using: symmetric, authenticating: context(for: envelope))
        guard let sealed = box.combined else { throw CocoaError(.coderInvalidValue) }
        envelope.sealed = sealed
        return try JSONEncoder().encode(envelope)
    }

    /// Throws `OpenError.wrongPassphrase` when the key does not open it,
    /// `OpenError.corruptedData` when what it opened is damaged.
    static func open(_ envelope: SyncEnvelope, with key: Key) throws -> Data {
        try open(envelope, with: key.key)
    }

    static func open(_ envelope: SyncEnvelope, with key: SymmetricKey) throws -> Data {
        guard let box = try? CryptoKit.AES.GCM.SealedBox(combined: envelope.sealed),
              let packed = try? CryptoKit.AES.GCM.open(box, using: key, authenticating: context(for: envelope))
        else { throw OpenError.wrongPassphrase }
        guard let plain = try? (packed as NSData).decompressed(using: .zlib) as Data else {
            throw OpenError.corruptedData
        }
        return plain
    }
}
