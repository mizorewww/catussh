//
//  CloudSync.swift
//  CatusshModule
//
//  Keeps the servers and identities of this device and of the user's other
//  devices the same, through iCloud. It is off until turned on in Settings.
//

import Combine
import Foundation
#if canImport(UIKit)
    import UIKit
#endif

@MainActor
public final class CloudSync: ObservableObject {
    public static let shared = CloudSync()

    public enum Status: Equatable {
        case off
        /// Sync cannot work here; the sentence says why.
        case unavailable(String)
        case syncing
        case synced(Date)
        /// This device's passphrase does not open what is in iCloud.
        case locked
        /// What is in iCloud cannot be read at all.
        case unreadable
        case failed(String)
    }

    @Published public private(set) var status: Status = .off
    @Published public private(set) var isOn: Bool

    @Published public var syncsServers: Bool {
        didSet {
            guard syncsServers != oldValue else { return }
            defaults.set(syncsServers, forKey: Key.servers)
            state.machines = [:]
            generation += 1
            sync()
        }
    }

    @Published public var syncsIdentities: Bool {
        didSet {
            guard syncsIdentities != oldValue else { return }
            defaults.set(syncsIdentities, forKey: Key.identities)
            state.identities = [:]
            generation += 1
            sync()
        }
    }

    /// Why sync cannot be turned on here, if it cannot.
    public var problem: String? {
        if !CatusshStore.savesChanges { return "catussh could not read its key from the keychain, so nothing is saved or synced." }
        return transport.problem
    }

    /// Whether iCloud already holds data, from this or another device.
    public var hasStoredData: Bool { transport.read() != nil }

    public static let minimumPassphraseLength = 8

    private enum Key {
        static let on = "me.mizorewww.rayon.sync.enabled"
        static let servers = "me.mizorewww.rayon.sync.servers"
        static let identities = "me.mizorewww.rayon.sync.identities"
    }

    /// The passphrase as it is kept on the device: with the servers and
    /// identities, under the app's master key.
    private struct Secret: Codable {
        var passphrase: String
    }

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
    private var observers: Set<AnyCancellable> = []

    private func scheduleDebouncedSync() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.sync()
        }
    }

    private init() {
        defaults.register(defaults: [Key.servers: true, Key.identities: true])
        isOn = defaults.bool(forKey: Key.on)
        syncsServers = defaults.bool(forKey: Key.servers)
        syncsIdentities = defaults.bool(forKey: Key.identities)
        #if DEBUG
            if ProcessInfo.processInfo.environment["CATUSSH_SYNC_LOCAL"] != nil {
                transport = LocalTransport()
            } else {
                transport = CloudKeyValueTransport()
            }
        #else
            transport = CloudKeyValueTransport()
        #endif
        passphrase = store.readEncryptedDefault(from: .syncPassphrase, Secret(passphrase: ""))?.passphrase
        if let saved = store.readEncryptedDefault(from: .syncState, SyncState()) { state = saved }
    }

    /// Call once the app has launched: syncs, and from then on syncs after
    /// every change here or on another device.
    public func start() {
        guard !started else { return }
        started = true
        transport.changed = { [weak self] in self?.sync() }
        // Asks iCloud for what it has, well before Settings asks whether
        // there is anything.
        _ = transport.read()
        // Only trigger sync when sync-relevant content changed, ignoring volatile
        // connection timestamps and banner updates.
        Publishers.Merge(
            store.$machineGroup
                .map { $0.machines.map(\.content) }
                .removeDuplicates()
                .dropFirst()
                .map { _ in () },
            store.$identityGroup
                .map { $0.identities.map(\.content) }
                .removeDuplicates()
                .dropFirst()
                .map { _ in () }
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
        #if canImport(UIKit)
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.sync() }
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

    // MARK: - Settings

    /// Turns sync on, or gives this device the passphrase again after it was
    /// refused.
    public func turnOn(passphrase new: String) {
        guard problem == nil else { return }
        set(passphrase: new)
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

    /// Puts this device's data in place of what is in iCloud, sealed under
    /// `passphrase` (or the current one). Other devices are then asked for it.
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

    /// Removes what is in iCloud and stops syncing here. A device that still
    /// syncs will store its data again.
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
        guard let passphrase, !passphrase.isEmpty else {
            status = .locked
            return
        }
        if running {
            pending = true
            return
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
        input.syncsMachines = syncsServers
        input.syncsIdentities = syncsIdentities
        input.replacesRemote = replacesNext
        replacesNext = false

        let round = input
        let read = generation
        Task {
            // Deriving a key takes a few hundred milliseconds.
            let outcome = await Task.detached(priority: .utility) { SyncSession.run(round) }.value
            if read == generation {
                finish(outcome)
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

    private func finish(_ outcome: SyncOutcome) {
        guard isOn else { return }
        switch outcome {
        case .locked:
            status = .locked
        case .unreadable:
            status = .unreadable
        case .newer:
            status = .failed("What is in iCloud was written by a newer version of catussh. Update catussh on this device.")
        case let .done(done):
            key = done.key
            if !done.machines.isEmpty {
                var group = store.machineGroup
                for change in done.machines {
                    switch change {
                    case let .put(machine): group.insert(machine)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.machineGroup = group
            }
            if !done.identities.isEmpty {
                var group = store.identityGroup
                for change in done.identities {
                    switch change {
                    case let .put(identity): group.insert(identity)
                    case let .remove(id): group.delete(id)
                    }
                }
                store.identityGroup = group
            }
            state = done.state
            if let upload = done.upload {
                do {
                    try transport.write(upload)
                } catch {
                    status = .failed(error.localizedDescription)
                    return
                }
            }
            status = .synced(Date())
        }
    }
}
