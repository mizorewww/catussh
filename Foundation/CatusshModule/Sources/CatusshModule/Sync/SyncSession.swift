//
//  SyncSession.swift
//  CatusshModule
//
//  One round of sync as a function: what this device has, what the store
//  holds, and out of them what to change here and what to upload. It touches
//  neither the store, the keychain nor the app, so it runs off the main thread.
//

import Foundation

struct SyncInput: Sendable {
    var machines: [RDMachine]
    var identities: [RDIdentity]
    var state: SyncState
    /// Nil or empty when this device has none.
    var passphrase: String?
    /// The stored envelope, if there is one.
    var remote: Data?
    /// A key derived from the passphrase earlier, to save deriving it again.
    var key: SyncCipher.Key?
    var snippets: [RDSnippet] = []
    var portForwards: [RDPortForward] = []
    var folders: [RDFolder] = []
    var settings: [String: SyncSetting] = [:]
    /// The keys this device has from iCloud Keychain, the newest first.
    var keychainKeys: [SyncKey] = []
    /// Whether this device can keep a key in iCloud Keychain. When it can,
    /// what it seals is sealed under such a key, unless what is stored is
    /// sealed under a passphrase by a version that can say so (one that chose
    /// a passphrase for want of iCloud Keychain).
    var usesKeychain = false
    var syncsMachines = true
    var syncsIdentities = true
    var syncsSnippets = true
    var syncsPortForwards = true
    var syncsSettings = true
    /// Seal under a new key, whatever is stored: a new key in iCloud Keychain
    /// when `usesKeychain`, else one from `passphrase`. What is stored is
    /// merged first if a key in hand (`key`, the passphrase one in use until
    /// now, or one of `keychainKeys`) still opens it; otherwise this device's
    /// data takes its place.
    var replacesRemote = false
    var now = Date()
    var rounds = SyncCipher.rounds
    var minimumRounds = SyncCipher.minimumRounds
}

enum SyncOutcome: Sendable {
    case done(Done)
    /// What is stored is sealed under a passphrase, and this device has none
    /// or the wrong one.
    case locked
    /// What is stored is sealed under a key from iCloud Keychain that has not
    /// reached this device (yet).
    case waitingForKey
    /// Nothing is stored and there is neither iCloud Keychain nor a passphrase
    /// to seal under.
    case needsPassphrase
    /// What is stored is not something this version wrote.
    case unreadable
    /// What is stored was written by a later version.
    case newer

    struct Done: Sendable {
        var machines: [SyncChange<RDMachine>] = []
        var identities: [SyncChange<RDIdentity>] = []
        var snippets: [SyncChange<RDSnippet>] = []
        var portForwards: [SyncChange<RDPortForward>] = []
        var folders: [SyncKeyedChange<RDFolder>] = []
        var settings: [SyncKeyedChange<SyncSetting>] = []
        var state: SyncState
        /// What the upload is sealed under, or would be.
        var sealing: SyncCipher.Sealing
        /// A key made in this round, to be put in iCloud Keychain before the
        /// upload is stored.
        var newKey: SyncKey?
        /// The envelope to store, when it changed.
        var upload: Data?

        /// The passphrase key, to keep for the next round.
        var key: SyncCipher.Key? {
            if case let .passphrase(key) = sealing { return key }
            return nil
        }
    }
}

enum SyncSession {
    static func run(_ input: SyncInput) -> SyncOutcome {
        var document = SyncDocument()
        var stored = false
        /// What opened what is stored.
        var opened: SyncCipher.Sealing?
        var openedVersion = SyncEnvelope.currentVersion
        let passphrase = input.passphrase.flatMap { $0.isEmpty ? nil : $0 }

        if input.replacesRemote {
            if let remote = input.remote,
               let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: remote),
               envelope.version <= SyncEnvelope.currentVersion
            {
                switch envelope.kind {
                case .keychain:
                    if let key = input.keychainKeys.first(where: { $0.id == envelope.keyID }),
                       let plain = try? SyncCipher.open(envelope, with: key.key),
                       let decoded = try? JSONDecoder().decode(SyncDocument.self, from: plain)
                    {
                        document = decoded
                    }
                case .passphrase:
                    if let old = input.key, envelope.salt == old.salt, envelope.rounds == old.rounds,
                       let plain = try? SyncCipher.open(envelope, with: old),
                       let decoded = try? JSONDecoder().decode(SyncDocument.self, from: plain)
                    {
                        document = decoded
                    }
                }
            }
        } else if let remote = input.remote {
            guard let envelope = try? JSONDecoder().decode(SyncEnvelope.self, from: remote) else {
                return .unreadable
            }
            guard envelope.version <= SyncEnvelope.currentVersion else { return .newer }
            let plain: Data
            switch envelope.kind {
            case .keychain:
                guard let id = envelope.keyID else { return .unreadable }
                guard let key = input.keychainKeys.first(where: { $0.id == id }) else { return .waitingForKey }
                do {
                    plain = try SyncCipher.open(envelope, with: key.key)
                } catch {
                    // The key is the one named, so it is the data that is
                    // damaged.
                    return .unreadable
                }
                opened = .keychain(key)
            case .passphrase:
                guard let salt = envelope.salt, let rounds = envelope.rounds,
                      (input.minimumRounds ... SyncCipher.maximumRounds).contains(rounds),
                      salt.count >= 8
                else { return .unreadable }
                var key = input.key
                if key?.salt != salt || key?.rounds != rounds {
                    guard let passphrase else { return .locked }
                    key = SyncCipher.key(passphrase: passphrase, salt: salt, rounds: rounds)
                }
                guard let key else { return .locked }
                do {
                    plain = try SyncCipher.open(envelope, with: key)
                } catch SyncCipher.OpenError.wrongPassphrase {
                    return .locked
                } catch {
                    // Damaged data is not a wrong passphrase: asking for another
                    // one would not help.
                    return .unreadable
                }
                opened = .passphrase(key)
            }
            guard let decoded = try? JSONDecoder().decode(SyncDocument.self, from: plain) else {
                return .unreadable
            }
            document = decoded
            stored = true
            openedVersion = envelope.version
        }

        // What to seal under. A key that opened what is stored seals it again,
        // except a passphrase that sealed a version 1 envelope (which could
        // not be sealed any other way) where iCloud Keychain can take over:
        // the other devices then need nothing.
        var sealing: SyncCipher.Sealing
        var newKey: SyncKey?
        var migrates = false
        func keychainKey() -> SyncKey {
            if let key = input.keychainKeys.first { return key }
            let key = SyncKey.generate()
            newKey = key
            return key
        }
        if input.replacesRemote {
            if input.usesKeychain {
                let key = SyncKey.generate()
                newKey = key
                sealing = .keychain(key)
            } else {
                guard let passphrase else { return .needsPassphrase }
                sealing = .passphrase(SyncCipher.key(
                    passphrase: passphrase, salt: SyncCipher.newSalt(), rounds: input.rounds
                ))
            }
        } else if let opened {
            sealing = opened
            if case .passphrase = opened, openedVersion < 2, input.usesKeychain {
                sealing = .keychain(keychainKey())
                migrates = true
            }
        } else if input.usesKeychain {
            sealing = .keychain(keychainKey())
        } else if let key = input.key {
            sealing = .passphrase(key)
        } else if let passphrase {
            sealing = .passphrase(SyncCipher.key(
                passphrase: passphrase, salt: SyncCipher.newSalt(), rounds: input.rounds
            ))
        } else {
            return .needsPassphrase
        }

        var state = input.state
        var dirty = !stored || migrates
        var done = SyncOutcome.Done(state: state, sealing: sealing, newKey: newKey)

        // A kind that is not synced here is passed on as it was stored.
        if input.syncsMachines {
            let merged = SyncMerge.reconcile(
                local: input.machines, state: &state.machines, remote: document.machines, now: input.now
            )
            document.machines = merged.entries
            done.machines = merged.itemChanges()
            dirty = dirty || merged.dirty

            var folders: [String: RDFolder] = [:]
            for folder in input.folders where !folder.name.isEmpty { folders[folder.name] = folder }
            let mergedFolders = SyncMerge.reconcile(
                local: folders, state: &state.folders, remote: document.folders, now: input.now
            )
            document.folders = mergedFolders.entries
            done.folders = mergedFolders.changes
            dirty = dirty || mergedFolders.dirty
        }
        if input.syncsIdentities {
            let merged = SyncMerge.reconcile(
                local: input.identities, state: &state.identities, remote: document.identities, now: input.now
            )
            document.identities = merged.entries
            done.identities = merged.itemChanges()
            dirty = dirty || merged.dirty
        }
        if input.syncsSnippets {
            let merged = SyncMerge.reconcile(
                local: input.snippets, state: &state.snippets, remote: document.snippets, now: input.now
            )
            document.snippets = merged.entries
            done.snippets = merged.itemChanges()
            dirty = dirty || merged.dirty
        }
        if input.syncsPortForwards {
            let merged = SyncMerge.reconcile(
                local: input.portForwards, state: &state.portForwards, remote: document.portForwards, now: input.now
            )
            document.portForwards = merged.entries
            done.portForwards = merged.itemChanges()
            dirty = dirty || merged.dirty
        }
        if input.syncsSettings {
            let merged = SyncMerge.reconcile(
                local: input.settings, state: &state.settings, remote: document.settings, now: input.now
            )
            document.settings = merged.entries
            done.settings = merged.changes
            dirty = dirty || merged.dirty
        }

        if dirty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let plain = try? encoder.encode(document),
                  let sealed = try? SyncCipher.seal(plain, with: sealing)
            else { return .unreadable }
            done.upload = sealed
        } else {
            // Nothing is uploaded, so nothing is sealed under a new key.
            done.newKey = nil
        }
        done.state = state
        return .done(done)
    }
}
