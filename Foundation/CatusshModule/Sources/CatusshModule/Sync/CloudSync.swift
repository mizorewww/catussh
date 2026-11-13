//
//  CloudSync.swift
//  CatusshModule
//
//  Keeps the servers, identities, snippets, port forwards and settings of this
//  device and of the user's other devices the same, through iCloud. It is off
//  until turned on in Settings.
//
//  What is in iCloud is sealed under a key that iCloud Keychain carries to the
//  user's other devices, so turning sync on is all there is to it. A device
//  that cannot keep a key in iCloud Keychain uses a passphrase instead.
//

import Combine
import Foundation
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
public final class CloudSync: ObservableObject {
    public static let shared = CloudSync()

    /// Posted when settings from another device were taken, for what the app
    /// applies itself (the appearance).
    public static let settingsDidChange = Notification.Name("CloudSyncSettingsDidChange")

    public enum Status: Equatable {
        case off
        /// Sync cannot work here; the sentence says why.
        case unavailable(String)
        case syncing
        case synced(Date)
        /// What is in iCloud is sealed under a key from iCloud Keychain that
        /// has not reached this device yet.
        case waitingForKey
        /// What is in iCloud is sealed under a passphrase this device does not
        /// have.
        case locked
        /// There is no iCloud Keychain here, and so no key without a passphrase.
        case needsPassphrase
        /// What is in iCloud cannot be read at all.
        case unreadable
        case failed(String)
    }

    @Published public private(set) var status: Status = .off {
        didSet { scheduleRetryWhileWaiting() }
    }

    @Published public private(set) var isOn: Bool

    /// Whether the key is kept in iCloud Keychain. When it is not, a
    /// passphrase takes its place.
    @Published public private(set) var usesKeychain: Bool

    @Published public var syncsServers: Bool {
        didSet { kindChanged(syncsServers, oldValue, Key.servers) { $0.machines = [:]; $0.folders = [:] } }
    }

    @Published public var syncsIdentities: Bool {
        didSet { kindChanged(syncsIdentities, oldValue, Key.identities) { $0.identities = [:] } }
    }

    @Published public var syncsSnippets: Bool {
        didSet { kindChanged(syncsSnippets, oldValue, Key.snippets) { $0.snippets = [:] } }
    }

    @Published public var syncsPortForwards: Bool {
        didSet { kindChanged(syncsPortForwards, oldValue, Key.portForwards) { $0.portForwards = [:] } }
    }

    @Published public var syncsSettings: Bool {
        didSet { kindChanged(syncsSettings, oldValue, Key.settings) { $0.settings = [:] } }
    }

    /// Why sync cannot be turned on here, if it cannot.
    public var problem: String? {
        if !CatusshStore.savesChanges { return "catussh could not read its key from the keychain, so nothing is saved or synced." }
        return transport.problem
    }

    /// Whether iCloud already holds data, from this or another device.
    public var hasStoredData: Bool { transport.read() != nil }

    /// Whether this device has a passphrase for sync.
    public var hasPassphrase: Bool { !(passphrase ?? "").isEmpty }

    public static let minimumPassphraseLength = 8

    private enum Key {
        static let on = "me.mizorewww.rayon.sync.enabled"
        static let servers = "me.mizorewww.rayon.sync.servers"
        static let identities = "me.mizorewww.rayon.sync.identities"
        static let snippets = "me.mizorewww.rayon.sync.snippets"
        static let portForwards = "me.mizorewww.rayon.sync.portForwards"
        static let settings = "me.mizorewww.rayon.sync.settings"
    }

    /// The passphrase as it is kept on the device: with the servers and
    /// identities, under the app's master key.
    private struct Secret: Codable {
        var passphrase: String
    }

    /// How often a device waiting for the key from iCloud Keychain looks again.
    private static let keyRetryInterval: UInt64 = 30_000_000_000

    private let store = CatusshStore.shared
    private let defaults = UserDefaults.standard
    private let transport: SyncTransport
    private var passphrase: String?
    private var state = SyncState() {
        didSet {
            guard state != oldValue else { return }
            store.storeEncryptedDefault(to: .syncState, with: state)
        }
    }

    private var key: SyncCipher.Key?
    private var running = false
    private var pending = false
    private var replacesNext = false
    private var started = false
    /// Counts the changes to what a round reads, to tell a round that was
    /// overtaken by one.
    private var generation = 0
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    /// The settings as the last look found them, to tell a change to one from
    /// the many other writes to the user defaults.
    private var settings: [String: SyncSetting] = [:]

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    /// iCloud Keychain says nothing when a key arrives, so a device that waits
    /// for one looks again from time to time (and whenever the app comes to
    /// the front).
    private func scheduleRetryWhileWaiting() {
        guard status == .waitingForKey else {
            retryTask?.cancel()
            retryTask = nil
            return
        }
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.keyRetryInterval)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            if self.status == .waitingForKey { self.sync() }
        }
    }

    private func kindChanged(_ new: Bool, _ old: Bool, _ key: String, forget: (inout SyncState) -> Void) {
        guard new != old else { return }
        defaults.set(new, forKey: key)
        forget(&state)
        generation += 1
        sync()
    }

    private init() {
        defaults.register(defaults: [
            Key.servers: true, Key.identities: true, Key.snippets: true, Key.portForwards: true, Key.settings: true,
        ])
        isOn = defaults.bool(forKey: Key.on)
        syncsServers = defaults.bool(forKey: Key.servers)
        syncsIdentities = defaults.bool(forKey: Key.identities)
        syncsSnippets = defaults.bool(forKey: Key.snippets)
        #if os(macOS)
            syncsPortForwards = defaults.bool(forKey: Key.portForwards)
        #else
            // iPhone and iPad have no switch for forwards (port forwarding is
            // the Mac's), so they always carry the Mac's along, even where
            // the switch was turned off before it went.
            syncsPortForwards = true
            defaults.set(true, forKey: Key.portForwards)
        #endif
        syncsSettings = defaults.bool(forKey: Key.settings)
        #if DEBUG
            if ProcessInfo.processInfo.environment["CATUSSH_SYNC_LOCAL"] != nil {
                transport = LocalTransport()
            } else {
                transport = CloudKeyValueTransport()
            }
        #else
            transport = CloudKeyValueTransport()
        #endif
        usesKeychain = transport.problem == nil && SyncKeychain.isAvailable
        passphrase = store.readEncryptedDefault(from: .syncPassphrase, Secret(passphrase: ""))?.passphrase
        if let saved = store.readEncryptedDefault(from: .syncState, SyncState()) { state = saved }
    }

    /// Call once the app has launched: syncs, and from then on syncs after
    /// every change here or on another device.
    public func start() {
        guard !started else { return }
        started = true
        // Duplicates synced in by an earlier version go before they are
        // looked at.
        store.collapseUURemoteDuplicates()
        transport.changed = { [weak self] in self?.sync() }
        // Asks iCloud for what it has, well before Settings asks whether
        // there is anything.
        _ = transport.read()
        settings = SyncedSettings.snapshot()
        // Only trigger sync when sync-relevant content changed, ignoring volatile
        // connection timestamps and banner updates.
        Publishers.MergeMany(
            store.$machineGroup.map { $0.machines.map(\.content) }.removeDuplicates().dropFirst().map { _ in () }
                .eraseToAnyPublisher(),
            store.$identityGroup.map { $0.identities.map(\.content) }.removeDuplicates().dropFirst().map { _ in () }
                .eraseToAnyPublisher(),
            store.$snippetGroup.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$portForwardGroup.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$folderGroup.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.generation += 1
                self.scheduleDebouncedSync()
            }
        }
        .store(in: &observers)
        // Settings live in the user defaults, or are written there soon after
        // they change; @Published says so before the value is set. Either
        // way, they are looked at once the change is in place. The store
        // writes the defaults on a queue of its own, so the notification is
        // brought to the main thread before any closure here, all of which
        // belong to the main actor, sees it.
        Publishers.MergeMany(
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .map { _ in () }
                .eraseToAnyPublisher(),
            store.$machineRedacted.map { _ in () }.eraseToAnyPublisher(),
            store.$openInterfaceAutomatically.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.settingsMayHaveChanged() }
        }
        .store(in: &observers)
        #if canImport(UIKit)
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.sync() }
                }
                .store(in: &observers)
        #elseif canImport(AppKit)
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated {
                        // On the Mac the app comes to the front often; only a
                        // device that waits for something needs to look.
                        guard let self, self.status == .waitingForKey else { return }
                        self.sync()
                    }
                }
                .store(in: &observers)
        #endif
        #if DEBUG
            // CATUSSH_SYNC_LOCAL=<passphrase> also turns sync on.
            if let passphrase = ProcessInfo.processInfo.environment["CATUSSH_SYNC_LOCAL"],
               passphrase.count >= Self.minimumPassphraseLength
            {
                turnOn(passphrase: passphrase)
                return
            }
        #endif
        sync()
    }

    private func settingsMayHaveChanged() {
        let now = SyncedSettings.snapshot()
        guard now != settings else { return }
        settings = now
        generation += 1
        scheduleDebouncedSync()
    }

    // MARK: - Settings

    /// Turns sync on. With iCloud Keychain that is all. Without it, false:
    /// nothing happens until a passphrase is given with `turnOn(passphrase:)`.
    @discardableResult
    public func turnOn() -> Bool {
        guard problem == nil else { return false }
        usesKeychain = SyncKeychain.isAvailable
        guard usesKeychain || hasPassphrase else { return false }
        switchOn()
        return true
    }

    /// Turns sync on with a passphrase, or gives this device the passphrase
    /// again after it was refused.
    public func turnOn(passphrase new: String) {
        guard problem == nil else { return }
        set(passphrase: new)
        switchOn()
    }

    private func switchOn() {
        if !isOn {
            state = SyncState()
            isOn = true
            defaults.set(true, forKey: Key.on)
            generation += 1
            if !hasStoredData {
                // iCloud may not have delivered what another device stored
                // yet; give it a moment before storing over it.
                status = .syncing
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.sync()
                }
                return
            }
        }
        sync()
    }

    /// Stops syncing here. What is in iCloud, and on this device, stays.
    public func turnOff() {
        isOn = false
        defaults.set(false, forKey: Key.on)
        passphrase = nil
        key = nil
        store.removeDefault(.syncPassphrase)
        state = SyncState()
        store.removeDefault(.syncState)
        generation += 1
        status = .off
    }

    /// Puts this device's data in place of what is in iCloud (merged with it,
    /// when this device can read it), sealed under a new key: in iCloud
    /// Keychain, or from `passphrase` (or the current one) where there is no
    /// iCloud Keychain. Other devices pick up the new key from iCloud Keychain,
    /// or ask for the new passphrase.
    public func replaceStoredData(passphrase new: String? = nil) {
        guard isOn else { return }
        if let new {
            // The key in use until now is kept for the round: it reads what
            // is stored one last time.
            let old = key
            set(passphrase: new)
            key = old
        }
        replacesNext = true
        sync()
    }

    /// Makes a new key in iCloud Keychain, seals what is in iCloud under it,
    /// and removes the old keys.
    public func resetKey() {
        replaceStoredData()
    }

    /// Removes what is in iCloud, and the keys in iCloud Keychain, and stops
    /// syncing here. A device that still syncs will store its data again,
    /// under a key of its own.
    public func deleteStoredData() {
        do {
            try transport.write(nil)
        } catch {
            debugPrint("CloudSync: failed to delete stored data: \(error.localizedDescription)")
            // Staying on, with the failure showing: turning off would say
            // the data is gone when it is not.
            status = .failed("The data in iCloud could not be removed: \(error.localizedDescription)")
            return
        }
        if usesKeychain { SyncKeychain.removeKeys() }
        turnOff()
    }

    private func set(passphrase new: String) {
        passphrase = new
        key = nil
        store.storeEncryptedDefault(to: .syncPassphrase, with: Secret(passphrase: new))
    }

    // MARK: - Sync

    public func sync() {
        guard isOn else {
            status = .off
            return
        }
        if let problem {
            status = .unavailable(problem)
            return
        }
        if running {
            pending = true
            return
        }
        if !usesKeychain { usesKeychain = SyncKeychain.isAvailable }
        var keys: [SyncKey] = []
        if usesKeychain {
            do {
                keys = try SyncKeychain.keys()
            } catch SyncKeychain.Failure.unavailable {
                usesKeychain = false
            } catch {
                status = .failed("The key could not be read from the keychain. Unlock this device and try again.")
                return
            }
        }
        running = true
        if case .synced = status {} else { status = .syncing }

        var input = SyncInput(
            machines: store.machineGroup.machines,
            identities: store.identityGroup.identities,
            state: state,
            passphrase: passphrase,
            remote: transport.read(),
            key: key
        )
        input.snippets = store.snippetGroup.snippets
        input.portForwards = store.portForwardGroup.forwards
        input.folders = store.folderGroup.folders
        settings = SyncedSettings.snapshot()
        input.settings = settings
        input.keychainKeys = keys
        input.usesKeychain = usesKeychain
        input.syncsMachines = syncsServers
        input.syncsIdentities = syncsIdentities
        input.syncsSnippets = syncsSnippets
        input.syncsPortForwards = syncsPortForwards
        input.syncsSettings = syncsSettings
        input.replacesRemote = replacesNext
        replacesNext = false

        let round = input
        let read = generation
        Task {
            // Deriving a key from a passphrase takes a few hundred milliseconds.
            let outcome = await Task.detached(priority: .utility) { SyncSession.run(round) }.value
            if read == generation {
                finish(outcome, replaced: round.replacesRemote)
            } else {
                // Something was edited meanwhile: what the round worked out
                // is about data that is gone.
                replacesNext = replacesNext || round.replacesRemote
                pending = true
            }
            running = false
            if pending {
                pending = false
                sync()
            }
        }
    }

    private func finish(_ outcome: SyncOutcome, replaced: Bool) {
        guard isOn else { return }
        switch outcome {
        case .locked:
            status = .locked
        case .waitingForKey:
            status = .waitingForKey
        case .needsPassphrase:
            status = .needsPassphrase
        case .unreadable:
            status = .unreadable
        case .newer:
            status = .failed("What is in iCloud was written by a newer version of catussh. Update catussh on this device.")
        case let .done(done):
            if let newKey = done.newKey {
                // The key goes to iCloud Keychain before anything sealed
                // under it goes to iCloud.
                do {
                    try SyncKeychain.add(newKey)
                } catch SyncKeychain.Failure.unavailable {
                    usesKeychain = false
                    replacesNext = replaced
                    if hasPassphrase { pending = true } else { status = .needsPassphrase }
                    return
                } catch {
                    status = .failed("The key could not be saved to the keychain. Unlock this device and try again.")
                    return
                }
            }
            if let key = done.key { self.key = key }
            apply(done)
            state = done.state
            if let upload = done.upload {
                do {
                    try transport.write(upload)
                } catch {
                    status = .failed(error.localizedDescription)
                    return
                }
            }
            if replaced, case let .keychain(kept) = done.sealing {
                SyncKeychain.removeKeys(except: kept.id)
            }
            status = .synced(Date())
        }
    }

    private func apply(_ done: SyncOutcome.Done) {
        if !done.machines.isEmpty {
            store.machineGroup = applying(done.machines, to: store.machineGroup)
            // Other devices signed in to UU Remote made their own servers
            // for its devices before those had a shared id.
            store.collapseUURemoteDuplicates()
        }
        if !done.identities.isEmpty { store.identityGroup = applying(done.identities, to: store.identityGroup) }
        if !done.snippets.isEmpty { store.snippetGroup = applying(done.snippets, to: store.snippetGroup) }
        if !done.portForwards.isEmpty {
            store.portForwardGroup = applying(done.portForwards, to: store.portForwardGroup)
        }
        if !done.folders.isEmpty {
            var group = store.folderGroup
            for change in done.folders {
                switch change {
                case let .put(name, folder):
                    if let index = group.folders.firstIndex(where: { $0.name == name }) {
                        group.folders[index] = folder
                    } else {
                        group.folders.append(folder)
                    }
                case let .remove(name):
                    group.folders.removeAll { $0.name == name }
                }
            }
            store.folderGroup = group
        }
        if !done.settings.isEmpty {
            SyncedSettings.apply(done.settings)
            // Taken, so not to be mistaken for a change made here.
            settings = SyncedSettings.snapshot()
            NotificationCenter.default.post(name: Self.settingsDidChange, object: self)
        }
    }

    /// The group with the changes made. An item is taken as it came, even one
    /// the group would not insert: refusing it here would read as deleting it
    /// here, and the deletion would be synced.
    private func applying<Group: RDGroup>(_ changes: [SyncChange<Group.Item>], to group: Group) -> Group
        where Group.Item.ID == UUID
    {
        var group = group
        for change in changes {
            switch change {
            case let .put(item):
                if let index = group.items.firstIndex(where: { $0.id == item.id }) {
                    group.items[index] = item
                } else {
                    group.items.append(item)
                }
            case let .remove(id):
                group.delete(id)
            }
        }
        return group
    }
}
