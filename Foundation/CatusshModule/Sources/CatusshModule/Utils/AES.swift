//
//  AES.swift
//  PTFoundation
//
//  Created by Lakr Aream on 12/15/20.
//

import CommonCrypto
import CryptoKit
import Foundation
import Keychain
import os

#if os(macOS) || targetEnvironment(macCatalyst)
    import IOKit
#endif

/// A keychain the app cannot reach through `SecItem`.
public struct LegacyKeyStore: Sendable {
    public enum ReadResult: Sendable {
        case found(String)
        /// There is no key: nothing was ever stored.
        case absent
        /// There may be a key, but it could not be read (access was denied).
        case unavailable
    }

    public let read: @Sendable () -> ReadResult
    public let write: @Sendable (String) -> Bool

    public init(read: @escaping @Sendable () -> ReadResult, write: @escaping @Sendable (String) -> Bool) {
        self.read = read
        self.write = write
    }
}

public struct AES: Sendable {
    private let key: Data
    private let legacyKey: Data?
    private let legacyIV: Data?

    /// Key material for an engine tried when this one cannot open the data,
    /// so what older DEBUG builds stored under the constant key stays
    /// readable. It never writes: the next save moves the data to this
    /// engine's key.
    private var keyFallback: String?

    /// The key could not be read or saved, so it lasts for this run only.
    /// Nothing is written with such a key: it would replace data that the real
    /// key can still read.
    public private(set) var isEphemeral = false

    private static let legacyKeyStoreStorage = OSAllocatedUnfairLock<LegacyKeyStore?>(initialState: nil)

    /// Set before `AES.shared` (and so `CatusshStore.shared`) is first used;
    /// the lock keeps a late read from racing the one-time registration.
    public static var legacyKeyStore: LegacyKeyStore? {
        get { legacyKeyStoreStorage.withLock { $0 } }
        set { legacyKeyStoreStorage.withLock { $0 = newValue } }
    }

    public static let shared: AES = {
        #if DEBUG && (os(macOS) || targetEnvironment(macCatalyst))
            var keyBuilder = legacyDebugKey
            let platformExpert = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("IOPlatformExpertDevice")
            )
            if platformExpert > 0 {
                defer { IOObjectRelease(platformExpert) }
                if let prop = IORegistryEntryCreateCFProperty(
                    platformExpert,
                    kIOPlatformSerialNumberKey as CFString,
                    kCFAllocatorDefault,
                    0
                ),
                    let serialNumber = prop.takeRetainedValue() as? String,
                    !serialNumber.isEmpty
                {
                    keyBuilder = serialNumber
                }
            }
            return makeEngine(key: keyBuilder + keyBuilder + keyBuilder)
        #else
            let engine = makeKeychainEngine()
            #if DEBUG
                return engine.withLegacyDebugKeyFallback()
            #else
                return engine
            #endif
        #endif
    }()

    #if DEBUG
        static let legacyDebugKey = "fdaisohfiuhfq34hifgraskhfiarhfgui34hibrfiuef"

        func withLegacyDebugKeyFallback() -> AES {
            var copy = self
            copy.keyFallback = Self.legacyDebugKey + Self.legacyDebugKey + Self.legacyDebugKey
            return copy
        }
    #endif

    /// Generates a full 256-bit cryptographically random master key string.
    public static func generateRandomMasterKey() -> String {
        let symmetric = SymmetricKey(size: .bits256)
        return symmetric.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    /// A random master key persisted in the keychain, with bridges for the
    /// keys earlier builds kept elsewhere.
    private static func makeKeychainEngine() -> AES {
        let keychainServiceID = "me.mizorewww.rayon.kcAccess"
        let masterKeyID = "me.mizorewww.rayon.MasterCrypto"
        let keychain = Keychain(service: keychainServiceID)
            .label("catussh Master Crypto Key")
            .comment("catussh requires a master crypto key to access your encrypted data on disk and protects your accounts")

        let formerKeychain = Keychain(service: "wiki.qaq.rayon.kcAccess")
        let formerMasterKeyID = "wiki.qaq.rayon.MasterCrypto"

        func stored() throws -> String? {
            if let master = try keychain.getString(masterKeyID), master.count > 2 { return master }
            if let master = try? formerKeychain.getString(formerMasterKeyID), master.count > 2 { return master }
            return nil
        }
        func store(_ new: String) -> Bool {
            do {
                try keychain.remove(masterKeyID)
                try keychain.set(new, key: masterKeyID)
                return true
            } catch {
                debugPrint("AES: keychain write failed: \(error.localizedDescription)")
                return false
            }
        }

        var key: String?
        var readFailed = false
        for _ in 0 ..< 3 {
            do {
                key = try stored()
                readFailed = false
                break
            } catch {
                readFailed = true
                debugPrint("AES: keychain access failed: \(error.localizedDescription)")
            }
        }
        if let key { return makeEngine(key: key) }

        if let legacy = legacyKeyStore {
            switch legacy.read() {
            case let .found(master) where master.count > 2:
                if !readFailed { _ = store(master) }
                return makeEngine(key: master)
            case .unavailable:
                debugPrint("AES: the stored master key is unavailable, using an ephemeral key")
                return makeEngine(key: generateRandomMasterKey(), ephemeral: true)
            case .found, .absent:
                break
            }
        } else if readFailed {
            debugPrint("AES: the master key could not be read, using an ephemeral key")
            return makeEngine(key: generateRandomMasterKey(), ephemeral: true)
        }

        let new = generateRandomMasterKey()
        if (!readFailed && store(new)) || legacyKeyStore?.write(new) == true {
            return makeEngine(key: new)
        }
        debugPrint("AES: no persisted master key, falling back to an ephemeral key")
        return makeEngine(key: generateRandomMasterKey(), ephemeral: true)
    }

    private static func makeEngine(key: String, ephemeral: Bool = false) -> AES {
        guard var engine = AES(key: key) else {
            preconditionFailure("unreachable: key is non-empty")
        }
        engine.isEphemeral = ephemeral
        return engine
    }

    private static let hkdfSalt = Data("me.mizorewww.rayon.aes.hkdf.v2".utf8)
    private static let hkdfInfo = Data("catussh-aes-256-gcm".utf8)

    /// Derives a 256-bit key using CryptoKit HKDF<SHA256>, safely supporting arbitrary UTF-8 strings,
    /// while retaining the legacy 32-byte key / 16-byte IV derivation to seamlessly read `RGCM1` and CBC data.
    public init?(key initKey: String, iv initIV: String = "") {
        let inputBytes = Data(initKey.utf8)
        guard !inputBytes.isEmpty else { return nil }
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputBytes),
            salt: Self.hkdfSalt,
            info: Self.hkdfInfo,
            outputByteCount: 32
        )
        key = derived.withUnsafeBytes { Data($0) }

        let ivSource = initIV.isEmpty ? initKey : initIV
        if initKey.count >= kCCKeySizeAES128, ivSource.count >= kCCBlockSizeAES128 {
            var legacyK = initKey
            while legacyK.count < 32 { legacyK += legacyK }
            while legacyK.count > 32 { legacyK.removeLast() }
            legacyKey = Data(legacyK.utf8)

            var legacyV = ivSource
            while legacyV.count < kCCBlockSizeAES128 { legacyV += legacyV }
            while legacyV.count > kCCBlockSizeAES128 { legacyV.removeLast() }
            legacyIV = Data(legacyV.utf8)
        } else {
            legacyKey = nil
            legacyIV = nil
        }
    }

    // MARK: - API

    private static let currentFormatPrefix = Data("RGCM2".utf8)
    private static let legacyGCMFormatPrefix = Data("RGCM1".utf8)

    public func encrypt(data: Data) -> Data? {
        guard let sealed = try? CryptoKit.AES.GCM.seal(
            data, using: SymmetricKey(data: key)
        ).combined else {
            debugPrint("Error: Failed to encrypt data.")
            return nil
        }
        var result = Self.currentFormatPrefix
        result.append(sealed)
        return result
    }

    public func decrypt(data: Data) -> Data? {
        if data.starts(with: Self.currentFormatPrefix) || data.starts(with: Self.legacyGCMFormatPrefix) {
            if let plain = open(data: data) { return plain }
            if let plain = fallbackOpen(data: data) { return plain }
        } else {
            if let plain = fallbackOpen(data: data) { return plain }
            if let plain = open(data: data) { return plain }
        }
        debugPrint("Error: Failed to decrypt data.")
        return nil
    }

    private func fallbackOpen(data: Data) -> Data? {
        guard let material = keyFallback,
              let fallback = AES(key: material, iv: material)
        else { return nil }
        return fallback.open(data: data)
    }

    private func open(data: Data) -> Data? {
        if data.starts(with: Self.currentFormatPrefix) {
            guard let box = try? CryptoKit.AES.GCM.SealedBox(
                combined: data.dropFirst(Self.currentFormatPrefix.count)
            ),
                let plain = try? CryptoKit.AES.GCM.open(box, using: SymmetricKey(data: key))
            else {
                return nil
            }
            return plain
        }
        if data.starts(with: Self.legacyGCMFormatPrefix) {
            guard let legacyKey,
                  let box = try? CryptoKit.AES.GCM.SealedBox(
                      combined: data.dropFirst(Self.legacyGCMFormatPrefix.count)
                  ),
                  let plain = try? CryptoKit.AES.GCM.open(box, using: SymmetricKey(data: legacyKey))
            else {
                return nil
            }
            return plain
        }
        return legacyCBCDecrypt(data: data)
    }

    private func legacyCBCDecrypt(data: Data) -> Data? {
        guard let legacyKey, let legacyIV else { return nil }
        let cryptLength = data.count + kCCBlockSizeAES128
        var cryptData = Data(count: cryptLength)
        var bytesLength = 0
        let status = cryptData.withUnsafeMutableBytes { cryptBytes in
            data.withUnsafeBytes { dataBytes in
                legacyIV.withUnsafeBytes { ivBytes in
                    legacyKey.withUnsafeBytes { keyBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            legacyKey.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            cryptBytes.baseAddress,
                            cryptLength,
                            &bytesLength
                        )
                    }
                }
            }
        }
        guard UInt32(status) == UInt32(kCCSuccess) else { return nil }
        cryptData.removeSubrange(bytesLength ..< cryptData.count)
        return cryptData
    }
}
