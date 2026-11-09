//
//  KnownHosts.swift
//  CatusshModule
//
//  The host keys of the servers connected to so far. A server's key is saved
//  the first time it is seen; after that a connection to the same address is
//  only made when the server presents the same key, so someone answering in
//  the server's place is refused instead of being handed the password.
//

import CryptoKit
import Foundation
import NSRemoteShell

public final class KnownHosts: @unchecked Sendable {
    public struct HostKey: Equatable, Codable, Sendable {
        /// The algorithm as SSH names it, "ssh-ed25519" for one.
        public let type: String
        public let key: Data

        public init(type: String, key: Data) {
            self.type = type
            self.key = key
        }

        /// What `ssh-keygen -l` prints for the key.
        public var fingerprint: String {
            let digest = Data(SHA256.hash(data: key)).base64EncodedString()
            return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
        }
    }

    public static let shared = KnownHosts()

    private let defaults: UserDefaults
    private let storageKey: String
    private let crypto: AES
    private let lock = NSLock()
    /// In-memory cache of decrypted entries, protected by `lock`.
    private var cachedEntries: [String: String]?
    /// The keys refused since launch, to tell the user what was offered.
    private var refused: [String: HostKey] = [:]

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "me.mizorewww.rayon.knownHosts",
        crypto: AES = .shared
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.crypto = crypto
    }

    /// Has every connection of `NSRemoteShell` checked against the saved keys.
    public static func install() {
        _ = installed
    }

    private static let installed: Void = {
        NSRemoteShell.hostKeyVerifier = { host, port, type, key in
            KnownHosts.shared.accepts(HostKey(type: type, key: key), host: host, port: port.intValue)
        }
    }()

    /// True for the key saved for the address, and for the first key seen
    /// there, which is saved. False for any other key.
    public func accepts(_ offered: HostKey, host: String, port: Int) -> Bool {
        let name = Self.name(host: host, port: port)
        lock.lock()
        defer { lock.unlock() }
        var saved = entriesLocked()
        guard let line = saved[name] else {
            saved[name] = Self.line(for: offered)
            saveEntriesLocked(saved)
            refused[name] = nil
            return true
        }
        if line == Self.line(for: offered) {
            refused[name] = nil
            return true
        }
        refused[name] = offered
        return false
    }

    public func savedKey(host: String, port: Int) -> HostKey? {
        lock.lock()
        defer { lock.unlock() }
        return entriesLocked()[Self.name(host: host, port: port)].flatMap(Self.hostKey(from:))
    }

    /// The key the address offered that was refused, if one was since launch.
    public func refusedKey(host: String, port: Int) -> HostKey? {
        lock.lock()
        defer { lock.unlock() }
        return refused[Self.name(host: host, port: port)]
    }

    /// The next key the address presents is saved as its key.
    public func forget(host: String, port: Int) {
        let name = Self.name(host: host, port: port)
        lock.lock()
        defer { lock.unlock() }
        var saved = entriesLocked()
        saved[name] = nil
        saveEntriesLocked(saved)
        refused[name] = nil
    }

    public func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        cachedEntries = [:]
        defaults.removeObject(forKey: storageKey)
        refused.removeAll()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entriesLocked().count
    }

    /// Why a connection to the address was refused, when its host key was the
    /// reason; nil when it was not.
    public func refusalMessage(host: String, port: Int) -> String? {
        let name = Self.name(host: host, port: port)
        lock.lock()
        let offered = refused[name]
        let saved = entriesLocked()[name].flatMap(Self.hostKey(from:))
        lock.unlock()
        guard let offered else { return nil }
        var lines = ["The host key of \(host):\(port) has changed, so the connection was refused."]
        if let saved {
            lines.append("Saved: \(saved.type) \(saved.fingerprint)")
        }
        lines.append("Offered: \(offered.type) \(offered.fingerprint)")
        lines.append("If the server was reinstalled or its keys were replaced, choose Forget Host Key for it and connect again. If not, something may be intercepting the connection.")
        return lines.joined(separator: "\n")
    }

    private func entriesLocked() -> [String: String] {
        if let cachedEntries { return cachedEntries }
        if let encrypted = defaults.data(forKey: storageKey),
           let plain = crypto.decrypt(data: encrypted),
           let decoded = try? PropertyListDecoder().decode([String: String].self, from: plain)
        {
            cachedEntries = decoded
            return decoded
        }
        if let legacyDict = defaults.dictionary(forKey: storageKey) as? [String: String] {
            saveEntriesLocked(legacyDict)
            return legacyDict
        }
        cachedEntries = [:]
        return [:]
    }

    private func saveEntriesLocked(_ entries: [String: String]) {
        cachedEntries = entries
        guard !crypto.isEphemeral,
              let plain = try? PropertyListEncoder().encode(entries),
              let encrypted = crypto.encrypt(data: plain)
        else { return }
        defaults.set(encrypted, forKey: storageKey)
    }

    /// `[host]:port`, as known_hosts writes an address with a port.
    static func name(host: String, port: Int) -> String {
        "[\(host.trimmingCharacters(in: .whitespaces).lowercased())]:\(port)"
    }

    private static func line(for key: HostKey) -> String {
        key.type + " " + key.key.base64EncodedString()
    }

    private static func hostKey(from line: String) -> HostKey? {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let key = Data(base64Encoded: String(parts[1])) else { return nil }
        return HostKey(type: String(parts[0]), key: key)
    }
}

public extension NSRemoteShell {
    /// Why the last connection was refused over the server's host key; nil
    /// when the host key was not the reason.
    var hostKeyRefusal: String? {
        KnownHosts.shared.refusalMessage(host: remoteHost, port: remotePort.intValue)
    }
}

public extension RDMachine {
    /// The next host key this server presents is saved as its key.
    func forgetHostKey() {
        KnownHosts.shared.forget(host: remoteAddress, port: Int(remotePort) ?? 0)
    }
}
