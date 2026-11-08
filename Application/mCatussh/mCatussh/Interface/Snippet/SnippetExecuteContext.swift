//
//  SnippetExecuteContext.swift
//  mCatussh
//
//  The per-server run lives in CatusshModule.SnippetExecSession; this
//  context keeps the batch: terminals, progress and per-server close.
//

import CatusshModule
import CatusshTerminal
import NSRemoteShell
import SwiftUI

final class SnippetExecuteContext: ObservableObject, @unchecked Sendable {
    let snippet: RDSnippet
    let machineGroup: [RDMachine]
    let terminalGroup: [CatusshTerminalView]

    private let lock = NSLock()
    private var activeShells: [RDMachine.ID: NSRemoteShell] = [:]
    private var shouldContinue: [RDMachine.ID: Bool] = [:]

    @Published var interfaceAllocated = false

    @Published var running: [RDMachine] = []
    @Published var completed: [RDMachine] = []
    @Published var hasError: Bool = false
    @Published var completedProgress: Float = 0
    @Published var totalProgress: Float = 0

    static let queue = DispatchQueue(label: "me.mizorewww.snippet.exec", attributes: .concurrent)

    init(snippet: RDSnippet, machineGroup: [RDMachine]) {
        self.snippet = snippet
        self.machineGroup = machineGroup
        var buildTermUI = [CatusshTerminalView]()
        let fontSize = CatusshStore.shared.terminalFontSize
        for machine in machineGroup {
            let view = CatusshTerminalView()
            view.setTerminalFontSize(with: fontSize)
            buildTermUI.append(view)
            activeShells[machine.id] = NSRemoteShell.configured(for: machine, timeout: CatusshStore.shared.timeoutNumber)
            shouldContinue[machine.id] = true
        }
        terminalGroup = buildTermUI
        totalProgress = Float(machineGroup.count)
    }

    deinit {
        debugPrint("\(self) \(#function)")
    }

    func beginBootstrap() {
        interfaceAllocated = true
        running = machineGroup
        updateProgress()
        for idx in 0 ..< machineGroup.count {
            let machine = machineGroup[idx]
            let term = terminalGroup[idx]
            guard let shell = lock.withLock({ activeShells[machine.id] }) else { continue }
            SnippetExecuteContext.queue.async {
                self.createExecute(for: machine, shell: shell, term: term)
            }
        }
    }

    func updateProgress() {
        onMainThread { [weak self] in
            guard let self else { return }
            self.completedProgress = Float(self.completed.count)
            self.totalProgress = Float(self.machineGroup.count)
        }
    }

    func reportError() {
        onMainThread { [weak self] in self?.hasError = true }
    }

    func createExecute(for machine: RDMachine, shell: NSRemoteShell, term: CatusshTerminalView) {
        defer {
            moveToComplete(for: machine.id)
        }
        term.write("[*] connecting to host...\r\n")
        let outcome = SnippetExecSession(machine: machine, shell: shell).execute(
            snippet.code,
            onBegin: {
                term.write("[*] Execute Begin\r\n")
            },
            onOutput: { output in
                term.write(output)
            },
            withContinuationHandler: { [weak self] in
                self?.lock.withLock { self?.shouldContinue[machine.id] ?? false } ?? false
            }
        )
        switch outcome {
        case .completed:
            term.write("\r\n\r\n[*] Execution Completed ")
        case .connectFailed:
            term.write("[E] failed to connect\r\n")
            reportError()
        case .authenticateFailed:
            term.write("[E] failed to authenticate session\r\n")
            reportError()
        }
    }

    func moveToComplete(for mid: RDMachine.ID) {
        let shell = lock.withLock { () -> NSRemoteShell? in
            shouldContinue[mid] = false
            return activeShells.removeValue(forKey: mid)
        }
        if let shell {
            shell.requestDisconnectAndWait()
            shell.destroyPermanently()
        }
        onMainThread { [weak self] in
            guard let self else { return }
            defer { self.updateProgress() }
            if let index = self.running.firstIndex(where: { $0.id == mid }) {
                let get = self.running.remove(at: index)
                self.completed.append(get)
            }
        }
    }

    func close(for mid: RDMachine.ID) {
        let shell = lock.withLock { () -> NSRemoteShell? in
            shouldContinue[mid] = false
            return activeShells.removeValue(forKey: mid)
        }
        if let shell {
            SnippetExecuteContext.queue.async {
                shell.requestDisconnectAndWait()
                shell.destroyPermanently()
            }
        }
    }
}
