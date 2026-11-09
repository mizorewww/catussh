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
        #if os(macOS)
            if domain == "me.mizorewww.rayon" || domain == "me.mizorewww.rayon.debug",
               let d = domain
            {
                let containerPlist = "/Users/\(NSUserName())/Library/Containers/\(d)/Data/Library/Preferences/\(d).plist"
                if let containerDict = NSDictionary(contentsOfFile: containerPlist) as? [String: Any] {
                    let currentSaved = defaults.persistentDomain(forName: d) ?? [:]
                    let currentMachines = (currentSaved["machineGroupEncrypted"] as? Data)?.count ?? 0
                    let containerMachines = (containerDict["machineGroupEncrypted"] as? Data)?.count ?? 0
                    if containerMachines > currentMachines || currentSaved["me.mizorewww.rayon.uuremote.account"] == nil {
                        for (k, v) in containerDict where !k.hasPrefix("NSWindow Frame") && !k.hasPrefix("NSSplitView") {
                            defaults.set(v, forKey: k)
                        }
                    }
                }
            }
        #endif
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

    /// Stores everything the debounce is still holding. For when the app
    /// goes to the background or is about to terminate.
    func flushPendingWrites() {
        storeWritePrecondition()
        DeferredStoreWrites.shared.flush()
    }

    /// Removes a stored value, after any write of it that is still queued.
    func removeDefault(_ key: UserDefaultKey) {
        storeWritePrecondition()
        DeferredStoreWrites.shared.cancel(key)
        storeQueue.async {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
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
        let fg = (dic[UserDefaultKey.folderGroupEncrypted.rawValue] as? Data).flatMap {
            readEncrypted(from: $0, CatusshStore.shared.folderGroup.self)
        }
        onMainThread {
            // Assigning fires each didSet, which stores the value; the
            // extra writes this used to do stored the same bytes twice.
            CatusshStore.shared.identityGroup = ig
            CatusshStore.shared.machineGroup = mg
            CatusshStore.shared.snippetGroup = sg
            CatusshStore.shared.portForwardGroup = pg
            if let fg { CatusshStore.shared.folderGroup = fg }
        }
        return true
    }

    struct BackupArchive: Codable, Sendable {
        public var version: Int = 1
        public var exportedAt: Date = .init()
        public var machines: [RDMachine]
        public var identities: [RDIdentity]
        public var snippets: [RDSnippet]
        public var portForwards: [RDPortForward]
        public var folders: [RDFolder]
    }

    /// Exports all saved servers, identities, snippets, port forwards, and folders.
    /// If `passphrase` is non-empty, the JSON payload is encrypted with AES-256-GCM (HKDF).
    @MainActor
    func exportBackupData(passphrase: String = "") throws -> Data {
        let archive = BackupArchive(
            machines: machineGroup.machines,
            identities: identityGroup.identities,
            snippets: snippetGroup.snippets,
            portForwards: portForwardGroup.forwards,
            folders: folderGroup.folders
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let raw = try encoder.encode(archive)
        let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        guard let aes = AES(key: trimmed), let encrypted = aes.encrypt(data: raw) else {
            throw NSError(domain: "CatusshBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encrypt backup archive."])
        }
        return encrypted
    }

    /// Imports a backup archive, merging or replacing items by UUID.
    @MainActor
    @discardableResult
    func importBackupData(_ data: Data, passphrase: String = "") throws -> (machines: Int, identities: Int, snippets: Int, forwards: Int) {
        let payload: Data
        if data.starts(with: Data("RGCM".utf8)) {
            let trimmed = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let aes = AES(key: trimmed), let plain = aes.decrypt(data: data) {
                payload = plain
            } else if let plain = AES.shared.decrypt(data: data) {
                payload = plain
            } else {
                throw NSError(domain: "CatusshBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: "Incorrect backup passphrase or corrupted encrypted archive."])
            }
        } else {
            payload = data
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(BackupArchive.self, from: payload)

        var mg = machineGroup
        for m in archive.machines { mg.insert(m) }
        machineGroup = mg

        var ig = identityGroup
        for i in archive.identities { ig.insert(i) }
        identityGroup = ig

        var sg = snippetGroup
        for s in archive.snippets { sg.insert(s) }
        snippetGroup = sg

        var pg = portForwardGroup
        for p in archive.portForwards { pg.insert(p) }
        portForwardGroup = pg

        var fg = folderGroup
        for f in archive.folders where !fg.folders.contains(where: { $0.name == f.name }) {
            fg.folders.append(f)
        }
        folderGroup = fg
        flushPendingWrites()
        return (archive.machines.count, archive.identities.count, archive.snippets.count, archive.portForwards.count)
    }

    /// Parses an OpenSSH `~/.ssh/config` text and imports any non-wildcard `Host` entries
    /// (along with referenced `IdentityFile` keys and `ProxyJump` links).
    @MainActor
    @discardableResult
    func importOpenSSHConfig(_ text: String, baseDirectory: URL? = nil) -> (importedServers: Int, importedIdentities: Int) {
        struct RawHostBlock {
            var aliases: [String] = []
            var hostName: String?
            var user: String?
            var port: String?
            var identityFile: String?
            var proxyJump: String?
        }

        var blocks: [RawHostBlock] = []
        var current: RawHostBlock?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            var value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            if key == "host" {
                if let current { blocks.append(current) }
                let aliases = value.split(whereSeparator: \.isWhitespace).map(String.init).filter {
                    !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!")
                }
                current = RawHostBlock(aliases: aliases)
            } else if current != nil {
                switch key {
                case "hostname": current?.hostName = value
                case "user": current?.user = value
                case "port": current?.port = value
                case "identityfile": if current?.identityFile == nil { current?.identityFile = value }
                case "proxyjump": current?.proxyJump = value
                default: break
                }
            }
        }
        if let current { blocks.append(current) }

        var importedServers = 0
        var importedIdentities = 0
        var aliasToMachineID: [String: UUID] = [:]
        var pendingProxyJump: [(machineID: UUID, jumpAlias: String)] = []

        var mg = machineGroup
        var ig = identityGroup

        for block in blocks {
            for alias in block.aliases {
                let host = block.hostName ?? alias
                let port = block.port ?? "22"
                guard !host.isEmpty else { continue }

                var associatedIdentityID: String?
                if let username = block.user, !username.isEmpty {
                    var loadedPriv = ""
                    var loadedPub = ""
                    if let idFile = block.identityFile {
                        let expanded = (idFile as NSString).expandingTildeInPath
                        let fileURL: URL
                        if expanded.hasPrefix("/") {
                            fileURL = URL(fileURLWithPath: expanded)
                        } else if let baseDirectory {
                            fileURL = baseDirectory.appendingPathComponent(expanded)
                        } else {
                            fileURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh").appendingPathComponent(expanded)
                        }
                        if let priv = try? String(contentsOf: fileURL, encoding: .utf8), RDIdentity.looksLikePrivateKey(priv) {
                            loadedPriv = priv
                            let pubURL = URL(fileURLWithPath: fileURL.path + ".pub")
                            if let pub = try? String(contentsOf: pubURL, encoding: .utf8) {
                                loadedPub = pub
                            }
                        }
                    }

                    if let existing = ig.identities.first(where: {
                        $0.username == username && (loadedPriv.isEmpty || $0.privateKey == loadedPriv)
                    }) {
                        associatedIdentityID = existing.id.uuidString
                    } else {
                        var newIdentity = RDIdentity(
                            username: username,
                            privateKey: loadedPriv,
                            publicKey: loadedPub,
                            comment: "Imported from ssh_config (\(alias))",
                            group: "SSH Config"
                        )
                        if loadedPriv.isEmpty {
                            newIdentity.useSSHAgent = true
                        }
                        ig.insert(newIdentity)
                        associatedIdentityID = newIdentity.id.uuidString
                        importedIdentities += 1
                    }
                }

                if let existingMachine = mg.machines.first(where: { $0.name == alias || ($0.remoteAddress == host && $0.remotePort == port && $0.name == alias) }) {
                    aliasToMachineID[alias] = existingMachine.id
                    continue
                }

                let machine = RDMachine(
                    remoteAddress: host,
                    remotePort: port,
                    name: alias,
                    group: "SSH Config",
                    lastConnection: Date(timeIntervalSince1970: 0),
                    comment: "Imported from ~/.ssh/config",
                    associatedIdentity: associatedIdentityID
                )
                mg.insert(machine)
                aliasToMachineID[alias] = machine.id
                if let jump = block.proxyJump, !jump.isEmpty, jump.lowercased() != "none" {
                    let firstJump = jump.split(separator: ",").first.map(String.init) ?? jump
                    pendingProxyJump.append((machine.id, firstJump.trimmingCharacters(in: .whitespaces)))
                }
                importedServers += 1
            }
        }

        for (machineID, jumpAlias) in pendingProxyJump {
            let resolvedJumpID = aliasToMachineID[jumpAlias]
                ?? mg.machines.first(where: { $0.name == jumpAlias || $0.remoteAddress == jumpAlias })?.id
            if let resolvedJumpID, resolvedJumpID != machineID {
                var m = mg[machineID]
                m.transport = .proxyJump
                m.proxyJumpMachineID = resolvedJumpID.uuidString
                mg[machineID] = m
            }
        }

        identityGroup = ig
        machineGroup = mg
        flushPendingWrites()
        return (importedServers, importedIdentities)
    }
}
