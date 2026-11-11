//
//  CatusshStore.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/8.
//

import Combine
import Foundation
import NSRemoteShell
import os
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// @unchecked Sendable: what the store keeps is written on the main
/// thread only (enforced in `storeEncryptedDefault`), and what a worker
/// queue may read is mirrored into `workerState` under its lock.
public class CatusshStore: ObservableObject, @unchecked Sendable {
    public init() {
        defer {
            debugPrint("CatusshStore init completed")
        }

        // Before anything is read: the settings may still be under their
        // former names.
        Self.adoptFormerDefaults()

        // Before any connection: every one is checked against the saved host keys.
        KnownHosts.install()

        // bool(forKey:) also reads "YES"/"1" from the argument domain
        // (`-licenseAgreed YES`), and is false when the key is missing.
        let defaults = UserDefaults.standard
        licenseAgreed = defaults.bool(forKey: UserDefaultKey.licenseAgreed.rawValue)
        storeRecent = Self.readDefaultBool("me.mizorewww.rayon.storeRecent", defaultValue: true, in: defaults)
        saveTemporarySession = Self.readDefaultBool("me.mizorewww.rayon.saveTemporarySession", defaultValue: true, in: defaults)
        timeout = Self.readDefaultInt("me.mizorewww.rayon.timeout", defaultValue: 5, in: defaults)
        reducedViewEffects = Self.readDefaultBool("me.mizorewww.rayon.reducedViewEffects", defaultValue: false, in: defaults)
        disableConformation = Self.readDefaultBool("me.mizorewww.rayon.disableConformation", defaultValue: false, in: defaults)
        monitorInterval = Self.readDefaultInt("me.mizorewww.rayon.monitorInterval", defaultValue: 3, in: defaults)
        terminalFontSize = Self.readDefaultInt("me.mizorewww.rayon.terminalFontSize", defaultValue: 14, in: defaults)
        terminalCopyOnSelect = Self.readDefaultBool("me.mizorewww.rayon.terminalCopyOnSelect", defaultValue: true, in: defaults)
        maxRecentRecordCount = Self.readDefaultInt("me.mizorewww.rayon.maxRecentRecordCount", defaultValue: 8, in: defaults)
        if timeout <= 0 { timeout = 5 }

        if let read = readEncryptedDefault(
            from: .identityGroupEncrypted,
            identityGroup.self
        ) {
            identityGroup = read
        }
        if let read = readEncryptedDefault(
            from: .machineGroupEncrypted,
            machineGroup.self
        ) {
            machineGroup = read
        }
        if let read = readEncryptedDefault(
            from: .folderGroupEncrypted,
            folderGroup.self
        ) {
            folderGroup = read
        }
        if let read = readEncryptedDefault(
            from: .machineRedacted,
            machineRedacted.self
        ) {
            machineRedacted = read
        }
        if let read = readEncryptedDefault(
            from: .snippetGroupEncrypted,
            snippetGroup.self
        ) {
            snippetGroup = read
        }
        if let read = readEncryptedDefault(
            from: .recentRecordEncrypted,
            recentRecord.self
        ) {
            recentRecord = read
        }
        if let read = readEncryptedDefault(
            from: .openInterfaceAutomatically,
            openInterfaceAutomatically.self
        ) {
            openInterfaceAutomatically = read
        }
        if let read = readEncryptedDefault(
            from: .portForwardEncrypted,
            portForwardGroup.self
        ) {
            portForwardGroup = read
        }

        // Property observers do not run during init; seed the worker
        // snapshot with what was just loaded.
        workerState.withLock {
            $0.machines = machineGroup.machines
            $0.identities = identityGroup.identities
            $0.timeout = timeout
            $0.monitorInterval = monitorInterval
            $0.terminalFontSize = terminalFontSize
        }

        // Storing is debounced; leaving the foreground writes what is
        // still waiting.
        #if canImport(UIKit)
            observers.append(NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.flushPendingWrites()
            })
        #elseif canImport(AppKit)
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.flushPendingWrites()
            })
        #endif
    }

    private var observers: [NSObjectProtocol] = []

    /// What worker queues read instead of the main-thread properties, kept
    /// in step by the property observers below. See CatusshStore+Worker.
    let workerState = OSAllocatedUnfairLock(initialState: WorkerState())

    /// First touched on the main thread at launch.
    public static let shared = CatusshStore()

    @Published public var licenseAgreed: Bool = false {
        didSet {
            storeDefault(to: .licenseAgreed, with: licenseAgreed)
        }
    }

    @Published public var globalProgressInPresent: Bool = false
    public var globalProgressCount: Int = 0 {
        didSet {
            if globalProgressCount == 0 {
                globalProgressInPresent = false
            } else {
                globalProgressInPresent = true
            }
        }
    }

    private static func readDefaultInt(_ key: String, defaultValue: Int, in defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.integer(forKey: key)
    }

    private static func readDefaultBool(_ key: String, defaultValue: Bool, in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    @Published public var timeout: Int = 5 {
        didSet {
            UserDefaults.standard.set(timeout, forKey: "me.mizorewww.rayon.timeout")
            workerState.withLock { $0.timeout = timeout }
        }
    }

    @Published public var monitorInterval: Int = 3 {
        didSet {
            UserDefaults.standard.set(monitorInterval, forKey: "me.mizorewww.rayon.monitorInterval")
            workerState.withLock { $0.monitorInterval = monitorInterval }
        }
    }

    /// Main thread; worker queues read `workerTimeoutNumber`.
    public var timeoutNumber: NSNumber {
        NSNumber(value: timeout)
    }

    @Published public var openInterfaceAutomatically: Bool = true {
        didSet {
            storeEncryptedDefault(
                to: .openInterfaceAutomatically,
                with: openInterfaceAutomatically
            )
        }
    }

    @Published public var identityGroup: RDIdentityGroup = .init() {
        didSet {
            workerState.withLock { $0.identities = identityGroup.identities }
            storeEncryptedDefault(
                to: .identityGroupEncrypted,
                with: identityGroup
            )
        }
    }

    /// Main thread; worker queues read `workerIdentitiesForAutoAuth`.
    public var identityGroupForAutoAuth: [RDIdentity] {
        identityGroup
            .identities
            .filter(\.authenticAutomatically)
            // make sure not to reopen too many times
            .sorted { $0.username < $1.username }
    }

    @Published public var machineRedacted: RDMachine.RedactedLevel = .none {
        didSet {
            storeEncryptedDefault(
                to: .machineRedacted,
                with: machineRedacted
            )
        }
    }

    @Published public var machineGroup: RDMachineGroup = .init() {
        didSet {
            workerState.withLock { $0.machines = machineGroup.machines }
            storeEncryptedDefault(
                to: .machineGroupEncrypted,
                with: machineGroup
            )
        }
    }

    @Published public var saveTemporarySession: Bool = true {
        didSet {
            UserDefaults.standard.set(saveTemporarySession, forKey: "me.mizorewww.rayon.saveTemporarySession")
        }
    }

    @Published public var storeRecent: Bool = true {
        didSet {
            UserDefaults.standard.set(storeRecent, forKey: "me.mizorewww.rayon.storeRecent")
            if !storeRecent {
                recentRecord = []
            }
        }
    }

    @Published public var reducedViewEffects: Bool = false {
        didSet {
            UserDefaults.standard.set(reducedViewEffects, forKey: "me.mizorewww.rayon.reducedViewEffects")
        }
    }

    @Published public var disableConformation: Bool = false {
        didSet {
            UserDefaults.standard.set(disableConformation, forKey: "me.mizorewww.rayon.disableConformation")
        }
    }

    public var maxRecentRecordCount: Int = 8 {
        didSet {
            UserDefaults.standard.set(maxRecentRecordCount, forKey: "me.mizorewww.rayon.maxRecentRecordCount")
        }
    }

    @Published public var recentRecord: [RecentConnection] = [] {
        didSet {
            storeEncryptedDefault(
                to: .recentRecordEncrypted,
                with: recentRecord
            )
        }
    }

    @Published public var terminalFontSize: Int = 14 {
        didSet {
            UserDefaults.standard.set(terminalFontSize, forKey: "me.mizorewww.rayon.terminalFontSize")
            workerState.withLock { $0.terminalFontSize = terminalFontSize }
        }
    }

    /// A finished selection in a terminal is copied to the clipboard.
    @Published public var terminalCopyOnSelect: Bool = true {
        didSet {
            UserDefaults.standard.set(terminalCopyOnSelect, forKey: "me.mizorewww.rayon.terminalCopyOnSelect")
        }
    }

    @Published public var snippetGroup: RDSnippetGroup = .init() {
        didSet {
            storeEncryptedDefault(
                to: .snippetGroupEncrypted,
                with: snippetGroup
            )
        }
    }

    /// Folders of servers; kept on this device. The servers carry their
    /// folder's name, which is what syncs.
    @Published public var folderGroup: RDFolderGroup = .init() {
        didSet {
            storeEncryptedDefault(
                to: .folderGroupEncrypted,
                with: folderGroup
            )
        }
    }

    @Published public var portForwardGroup: RDPortForwardGroup = .init() {
        didSet {
            storeEncryptedDefault(
                to: .portForwardEncrypted,
                with: portForwardGroup
            )
        }
    }
}
