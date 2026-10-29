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
import PropertyWrapper
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
        licenseAgreed = UserDefaults.standard.bool(forKey: UserDefaultKey.licenseAgreed.rawValue)
        storeRecent = UDStoreRecent
        saveTemporarySession = UDSaveTemporarySession
        timeout = UDTimeout
        reducedViewEffects = UDReducedViewEffects
        disableConformation = UDDisableConformation
        monitorInterval = UDMonitorInterval
        terminalFontSize = UDTerminalFontSize
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

    @UserDefaultsWrapper(key: "me.mizorewww.rayon.timeout", defaultValue: 5)
    private var UDTimeout: Int
    @Published public var timeout: Int = 0 {
        didSet {
            UDTimeout = timeout
            workerState.withLock { $0.timeout = timeout }
        }
    }

    @UserDefaultsWrapper(key: "me.mizorewww.rayon.monitorInterval", defaultValue: 3)
    private var UDMonitorInterval: Int
    @Published public var monitorInterval: Int = 0 {
        didSet {
            UDMonitorInterval = monitorInterval
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

    @UserDefaultsWrapper(key: "me.mizorewww.rayon.saveTemporarySession", defaultValue: true)
    private var UDSaveTemporarySession: Bool

    @Published public var saveTemporarySession: Bool = false {
        didSet {
            UDSaveTemporarySession = saveTemporarySession
        }
    }

    @UserDefaultsWrapper(key: "me.mizorewww.rayon.storeRecent", defaultValue: true)
    private var UDStoreRecent: Bool

    @Published public var storeRecent: Bool = false {
        didSet {
            UDStoreRecent = storeRecent
            if !storeRecent {
                recentRecord = []
            }
        }
    }

    @UserDefaultsWrapper(key: "me.mizorewww.rayon.reducedViewEffects", defaultValue: false)
    private var UDReducedViewEffects: Bool

    @Published public var reducedViewEffects: Bool = false {
        didSet {
            UDReducedViewEffects = reducedViewEffects
        }
    }

    @UserDefaultsWrapper(key: "me.mizorewww.rayon.disableConformation", defaultValue: false)
    private var UDDisableConformation: Bool

    @Published public var disableConformation: Bool = false {
        didSet {
            UDDisableConformation = disableConformation
        }
    }

    @UserDefaultsWrapper(key: "me.mizorewww.rayon.maxRecentRecordCount", defaultValue: 8)
    public var maxRecentRecordCount: Int

    @Published public var recentRecord: [RecentConnection] = [] {
        didSet {
            storeEncryptedDefault(
                to: .recentRecordEncrypted,
                with: recentRecord
            )
        }
    }

    @UserDefaultsWrapper(key: "me.mizorewww.rayon.terminalFontSize", defaultValue: 14)
    public var UDTerminalFontSize: Int

    @Published public var terminalFontSize: Int = 14 {
        didSet {
            UDTerminalFontSize = terminalFontSize
            workerState.withLock { $0.terminalFontSize = terminalFontSize }
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
