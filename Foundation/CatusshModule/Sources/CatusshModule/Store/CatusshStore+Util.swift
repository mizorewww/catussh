//
//  CatusshStore+Util.swift
//  catussh
//
//  Created by Lakr Aream on 2022/3/1.
//

import Foundation
import NSRemoteShell

private let documentEncoder = PropertyListEncoder()
private let documentDecoder = PropertyListDecoder()
private let crypto: AES = .shared
private let storeQueue = DispatchQueue(label: "me.mizorewww.rayon.store")

/// How long a change may wait before it is stored: monitoring touches the
/// machine group every few seconds per machine, and each touch used to be
/// a full encode + encrypt + write of the whole group.
private let storeWriteDebounce: TimeInterval = 1.5

/// Coalesces encrypted writes per key. The in-memory value changes at
/// once; only storing is deferred. Main thread only, like the store
/// itself: callers reach it through the store's main-thread write path.
private final class DeferredStoreWrites: @unchecked Sendable {
    static let shared = DeferredStoreWrites()

    private var pending: [CatusshStore.UserDefaultKey: (item: DispatchWorkItem, write: () -> Void)] = [:]

    func schedule(_ key: CatusshStore.UserDefaultKey, write: @escaping () -> Void) {
        pending[key]?.item.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pending[key] = nil
            storeQueue.async(execute: write)
        }
        pending[key] = (item, write)
        DispatchQueue.main.asyncAfter(deadline: .now() + storeWriteDebounce, execute: item)
    }

    func cancel(_ key: CatusshStore.UserDefaultKey) {
        pending[key]?.item.cancel()
        pending[key] = nil
    }

    /// Stores everything still waiting, in the order the writes were
    /// scheduled, and returns once the bytes are on disk.
    func flush() {
        let entries = pending
        pending.removeAll()
        for entry in entries {
            entry.value.item.cancel()
            // Serial and first-in-first-out: a write of the same key that
            // already fired runs first, this newer value lands after it.
            storeQueue.sync(execute: entry.value.write)
        }
    }
}

public extension CatusshStore {
    enum UserDefaultKey: String {
        case identityGroupEncrypted
        case machineGroupEncrypted
        case snippetGroupEncrypted
        case recentRecordEncrypted
        case portForwardEncrypted
        case folderGroupEncrypted
        case machineRedacted
        case licenseAgreed
        case openInterfaceAutomatically
        case syncPassphrase
        case syncState
    }

    /// Settings used to be saved under names that began with the former
    /// maintainer's domain. They are copied, once, to the names used now; the
    /// old ones are left as they were.
    static func adoptFormerDefaults(
        in defaults: UserDefaults = .standard,
        domain: String? = Bundle.main.bundleIdentifier
    ) {
        let adopted = "me.mizorewww.rayon.adoptedFormerDefaults"
        guard !defaults.bool(forKey: adopted) else { return }
        let former = "wiki.qaq."
        // The saved settings only: not what a launch argument says.
        let saved = domain.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        for (key, value) in saved where key.hasPrefix(former) {
            let name = "me.mizorewww." + key.dropFirst(former.count)
            if saved[name] == nil { defaults.set(value, forKey: name) }
        }
        defaults.set(true, forKey: adopted)
    }

    /// Nil means one of two things: nothing was ever stored, or what was
    /// stored cannot be read. The second case keeps the original bytes
    /// under a ".corrupt" key once, so a later write does not destroy the
    /// only copy.
    func readEncryptedDefault<T: Codable>(from key: UserDefaultKey, _: T) -> T? {
        guard let encryptedData = UserDefaults
            .standard
            .value(forKey: key.rawValue) as? Data
        else {
            return nil
        }
        guard let decrypted = crypto.decrypt(data: encryptedData) else {
            backupCorrupt(encryptedData, for: key, reason: "decryption failed")
            return nil
        }
        guard let objects = try? documentDecoder.decode(T.self, from: decrypted) else {
            backupCorrupt(encryptedData, for: key, reason: "decoding failed")
            return nil
        }
        return objects
    }

    private func backupCorrupt(_ blob: Data, for key: UserDefaultKey, reason: String) {
        let backupKey = key.rawValue + ".corrupt"
        debugPrint("CatusshStore: \(key.rawValue) is unreadable (\(reason)); the original bytes are kept under \(backupKey)")
        guard UserDefaults.standard.object(forKey: backupKey) == nil else { return }
        UserDefaults.standard.set(blob, forKey: backupKey)
    }

    func storeDefault(to key: UserDefaultKey, with data: Any) {
        storeWritePrecondition()
        UserDefaults
            .standard
            .set(data, forKey: key.rawValue)
    }

    /// Whether changes are being saved. False when the master key could not be
    /// read: the data on disk is left as it is until the key is available again.
    static var savesChanges: Bool { !crypto.isEphemeral }

    /// Writes of what the store keeps land on the main thread: the debounce
    /// table is main-thread state, and CloudSync's generation counting and
    /// Combine's synchronous delivery assume a change is published there.
    /// DEBUG builds crash on a violation instead of hiding it behind the
    /// main-queue hop.
    private func storeWritePrecondition() {
        #if DEBUG
            dispatchPrecondition(condition: .onQueue(.main))
        #endif
    }

    func storeEncryptedDefault<T: Codable>(to key: UserDefaultKey, with data: T) {
        guard !crypto.isEphemeral else { return }
        storeWritePrecondition()
        onMainThread {
            DeferredStoreWrites.shared.schedule(key) {
                guard let data = try? documentEncoder.encode(data),
                      let encrypt = crypto.encrypt(data: data)
                else {
                    debugPrint("CatusshStore: failed to encode or encrypt \(key.rawValue); the change is not stored")
                    return
                }
                UserDefaults
                    .standard
                    .set(encrypt, forKey: key.rawValue)
            }
        }
    }

    /// Stores everything the debounce is still holding. For when the app
    /// goes to the background or is about to terminate.
    func flushPendingWrites() {
        storeWritePrecondition()
        onMainThread {
            DeferredStoreWrites.shared.flush()
        }
    }

    /// Removes a stored value, after any write of it that is still queued.
    func removeDefault(_ key: UserDefaultKey) {
        storeWritePrecondition()
        onMainThread {
            DeferredStoreWrites.shared.cancel(key)
            storeQueue.async {
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            }
        }
    }

    func findSimilarMachine(
        withAddr: String,
        withPort: String,
        withUsername: String?
    ) -> RDMachine.ID? {
        guard withAddr.count > 0, withPort.count > 0 else {
            return nil
        }
        for machine in machineGroup.machines {
            if machine.remoteAddress == withAddr,
               machine.remotePort == withPort
            {
                if let withUsername = withUsername {
                    guard let sid = machine.associatedIdentity,
                          let rid = UUID(uuidString: sid)
                    else {
                        continue
                    }
                    let identity = identityGroup[rid]
                    if identity.username == withUsername {
                        return machine.id
                    } else {
                        continue
                    }
                } else {
                    return machine.id
                }
            }
        }
        return nil
    }
}

public extension CatusshStore {
    /// False when the data or the key could not be read; nothing was
    /// changed then.
    @discardableResult
    static func overrideImport(from data: Data, key: String) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) else {
            debugPrint("CatusshStore: unable to serialize property list")
            return false
        }
        guard let dic = plist as? [String: Any] else {
            debugPrint("CatusshStore: unexpected format")
            return false
        }
        guard let aes = AES(key: key, iv: key) else {
            debugPrint("CatusshStore: failed to load crypto engine")
            return false
        }

        func readEncrypted<T: Codable>(from data: Data, _: T) -> T? {
            if let decrypted = aes.decrypt(data: data),
               let objects = try? documentDecoder.decode(T.self, from: decrypted)
            {
                return objects
            }
            return nil
        }
        guard let identityGroupEncrypted = dic[UserDefaultKey.identityGroupEncrypted.rawValue] as? Data,
              let machineGroupEncrypted = dic[UserDefaultKey.machineGroupEncrypted.rawValue] as? Data,
              let snippetGroupEncrypted = dic[UserDefaultKey.snippetGroupEncrypted.rawValue] as? Data,
              let portForwardEncrypted = dic[UserDefaultKey.portForwardEncrypted.rawValue] as? Data,
              let ig = readEncrypted(from: identityGroupEncrypted, CatusshStore.shared.identityGroup.self),
              let mg = readEncrypted(from: machineGroupEncrypted, CatusshStore.shared.machineGroup.self),
              let sg = readEncrypted(from: snippetGroupEncrypted, CatusshStore.shared.snippetGroup.self),
              let pg = readEncrypted(from: portForwardEncrypted, CatusshStore.shared.portForwardGroup.self)
        else {
            debugPrint("CatusshStore: broken payload")
            return false
        }
        onMainThread {
            // Assigning fires each didSet, which stores the value; the
            // extra writes this used to do stored the same bytes twice.
            CatusshStore.shared.identityGroup = ig
            CatusshStore.shared.machineGroup = mg
            CatusshStore.shared.snippetGroup = sg
            CatusshStore.shared.portForwardGroup = pg
        }
        return true
    }
}
