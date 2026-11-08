//
//  BatchSnippetExecContext.swift
//  CatusshModule
//
//  Shared batch snippet execution context used by macOS and iOS.
//  Uses O(1) UTF-8 byte-ring buffers and publishes state transitions on @MainActor.
//

import Combine
import Foundation
import NSRemoteShell

public final class BatchSnippetExecContext: ObservableObject, @unchecked Sendable {
    public let snippet: RDSnippet
    public let machines: [RDMachine.ID]
    public let names: [RDMachine.ID: String]

    @Published public private(set) var completedCount: Int = 0
    @Published public private(set) var isRunning: Bool = false

    public init(snippet: RDSnippet, machines: [RDMachine.ID]) {
        self.snippet = snippet
        self.machines = machines
        var buildNames: [RDMachine.ID: String] = [:]
        for machine in machines {
            let object = CatusshStore.shared.machineGroup[machine]
            guard object.isNotPlaceholder() else {
                debugPrint("garbage machine found")
                receivedBuffer[machine] = Data("\r\n[*] Malformed Machine Info\r\n".utf8)
                continue
            }
            shellObjects[object.id] = NSRemoteShell
                .configured(for: object, timeout: CatusshStore.shared.timeoutNumber)
            shellContinue[object.id] = true
            buildNames[machine] = object.name
        }
        names = buildNames
    }

    deinit {
        debugPrint("\(self) \(#function)")
    }

    private var didStart = false

    public func start() {
        accessLock.lock()
        let shouldStart = !didStart
        didStart = true
        accessLock.unlock()
        guard shouldStart else { return }
        onMainThread { [weak self] in
            self?.isRunning = true
        }
        DispatchQueue.global().async {
            self.beingExecution()
        }
    }

    var shellObjects: [RDMachine.ID: NSRemoteShell] = [:]

    private var shellContinue: [RDMachine.ID: Bool] = [:]
    private var receivedBuffer: [RDMachine.ID: Data] = [:]
    private var completedMachines: [RDMachine.ID] = []
    private var consumedByteCount: [UUID: Int] = [:]
    private var droppedByteCount: [RDMachine.ID: Int] = [:]
    private var startedAt: [RDMachine.ID: Date] = [:]
    private var finishedAt: [RDMachine.ID: Date] = [:]
    private var failedMachines: Set<RDMachine.ID> = []

    public enum MachineState: Equatable {
        case waiting
        case running(since: Date)
        case done(duration: TimeInterval)
        case failed(duration: TimeInterval)

        public var isFinished: Bool {
            switch self {
            case .done, .failed: return true
            case .waiting, .running: return false
            }
        }
    }

    public func state(for machine: RDMachine.ID) -> MachineState {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard let start = startedAt[machine] else { return .waiting }
        if let end = finishedAt[machine] {
            let duration = end.timeIntervalSince(start)
            return failedMachines.contains(machine) ? .failed(duration: duration) : .done(duration: duration)
        }
        return .running(since: start)
    }

    /// Asks every running command to stop.
    public func stopAll() {
        let shellsToDisconnect: [NSRemoteShell] = accessLock.withLock {
            for key in shellContinue.keys {
                shellContinue[key] = false
            }
            let active = Array(shellObjects.values)
            shellObjects.removeAll()
            return active
        }
        DispatchQueue.global().async {
            for shell in shellsToDisconnect {
                shell.requestDisconnectAndWait()
            }
        }
    }

    /// Stops a single machine's execution.
    public func stop(machine: RDMachine.ID) {
        let shell: NSRemoteShell? = accessLock.withLock {
            shellContinue[machine] = false
            return shellObjects.removeValue(forKey: machine)
        }
        if let shell {
            DispatchQueue.global().async {
                shell.requestDisconnectAndWait()
            }
        }
    }

    public var safeAccessCompletedMachines: [RDMachine.ID] {
        accessLock.lock()
        defer { accessLock.unlock() }
        return completedMachines
    }

    public var hasFailures: Bool {
        accessLock.lock()
        defer { accessLock.unlock() }
        return !failedMachines.isEmpty
    }

    let accessLock = NSLock()
    func safeAccess(on: () -> Void) {
        accessLock.lock()
        on()
        accessLock.unlock()
    }

    func beingExecution() {
        let queue = DispatchQueue(
            label: "me.mizorewww.rayon.exec.batch.\(snippet.name)",
            attributes: .concurrent
        )
        let machines = machines
        queue.async {
            let group = DispatchGroup()
            for machine in machines {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    self.beginExec(on: machine)
                }
            }
            group.wait()
            onMainThread { [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.objectWillChange.send()
            }
        }
    }

    /// O(1) byte-indexed slice extraction from the per-machine output ring buffer.
    public func requestBuffer(for terminalId: UUID, machine: UUID) -> String {
        accessLock.lock()
        let buffer = receivedBuffer[machine] ?? Data()
        let dropped = droppedByteCount[machine, default: 0]
        let consumed = consumedByteCount[terminalId, default: 0]
        let totalAvailable = dropped + buffer.count
        guard consumed < totalAvailable else {
            accessLock.unlock()
            return ""
        }
        let sliceStart = max(0, consumed - dropped)
        let slice = buffer.dropFirst(sliceStart)
        consumedByteCount[terminalId] = totalAvailable
        accessLock.unlock()
        return String(decoding: slice, as: UTF8.self)
    }

    private static let bufferLimit = 1024 * 1024

    /// Call with accessLock held.
    private func lockedAppendToBuffer(_ output: String, for machine: RDMachine.ID) {
        let utf8 = Data(output.utf8)
        guard !utf8.isEmpty else { return }
        var current = receivedBuffer[machine] ?? Data()
        current.append(utf8)
        if current.count > Self.bufferLimit {
            let excess = current.count - Self.bufferLimit
            current = Data(current.dropFirst(excess))
            droppedByteCount[machine, default: 0] += excess
        }
        receivedBuffer[machine] = current
    }

    private func appendToBuffer(_ output: String, for machine: RDMachine.ID) {
        safeAccess {
            self.lockedAppendToBuffer(output, for: machine)
        }
    }

    func beginExec(on machine: RDMachine.ID) {
        safeAccess { self.startedAt[machine] = Date() }
        onMainThread { [weak self] in self?.objectWillChange.send() }

        var localShell: NSRemoteShell?
        safeAccess { localShell = self.shellObjects[machine] }

        defer {
            debugPrint("execution subroutine completed for machine: \(machine)")
            let doneCount: Int = accessLock.withLock {
                if !self.completedMachines.contains(machine) {
                    self.completedMachines.append(machine)
                }
                self.finishedAt[machine] = Date()
                self.shellObjects.removeValue(forKey: machine)
                return self.completedMachines.count
            }
            if let shell = localShell {
                shell.requestDisconnectAndWait()
                shell.destroyPermanently()
            }
            onMainThread { [weak self] in
                guard let self else { return }
                self.completedCount = doneCount
                self.objectWillChange.send()
            }
        }

        guard let shell = localShell else {
            debugPrint("missing shell for machine: \(machine)")
            safeAccess { self.failedMachines.insert(machine) }
            return
        }

        let remote = CatusshStore.shared.workerMachine(for: machine)
        guard remote.isNotPlaceholder() else {
            debugPrint("machine vanished mid-run: \(machine)")
            safeAccess { self.failedMachines.insert(machine) }
            return
        }
        let outcome = SnippetExecSession(machine: remote, shell: shell).execute(
            snippet.code,
            onBegin: {
                debugPrint("channel begin")
                self.appendToBuffer("[*] Execute Begin\r\n", for: machine)
            },
            onOutput: { output in
                self.appendToBuffer(output, for: machine)
            },
            withContinuationHandler: {
                self.accessLock.withLock { self.shellContinue[machine] ?? false }
            }
        )
        switch outcome {
        case .completed:
            safeAccess {
                self.lockedAppendToBuffer("\r\n[*] Execution completed\r\n", for: machine)
            }
        case .connectFailed:
            debugPrint("failed to connect to remote machine: \(machine)")
            safeAccess {
                self.lockedAppendToBuffer("\r\n[E] Could not connect to the server\r\n", for: machine)
                self.failedMachines.insert(machine)
            }
        case .authenticateFailed:
            debugPrint("auth failed for machine: \(machine)")
            safeAccess {
                self.lockedAppendToBuffer("\r\n[E] The identity could not sign in\r\n", for: machine)
                self.failedMachines.insert(machine)
            }
        }
    }
}
