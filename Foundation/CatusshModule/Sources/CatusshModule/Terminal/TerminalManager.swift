//
//  TerminalManager.swift
//  CatusshModule
//
//  Shared terminal session manager across macOS and iOS.
//

import CatusshTerminal
import Combine
import Foundation

extension TerminalSurfaceBridge: TerminalSessionSurface {}

@MainActor
public final class TerminalManager: ObservableObject {
    public static let shared = TerminalManager()

    private init() {}

    public final class Context: TerminalContext, @unchecked Sendable {
        private let surfaceBridge = TerminalSurfaceBridge()
        public var termInterface: CatusshTerminalView { surfaceBridge.termInterface }

        public init(machine: RDMachine) {
            super.init(machine: machine, surface: surfaceBridge)
            termInterface.setTerminalFontSize(with: CatusshStore.shared.terminalFontSize)
        }

        public init(command: SSHCommandReader) {
            super.init(command: command, surface: surfaceBridge)
            termInterface.setTerminalFontSize(with: CatusshStore.shared.terminalFontSize)
        }

        public init(localShell: Bool) {
            super.init(localShell: surfaceBridge)
            termInterface.setTerminalFontSize(with: CatusshStore.shared.terminalFontSize)
        }
    }

    @Published public var sessionContexts: [Context] = []

    /// Alias used by the iOS app.
    public var terminals: [Context] {
        get { sessionContexts }
        set { sessionContexts = newValue }
    }

    public func createSession(
        withMachineObject machine: RDMachine,
        resuming uuSession: UInt32? = nil,
        completion: @escaping (Context) -> Void = { _ in }
    ) {
        let context = Context(machine: machine)
        context.uuSessionID = uuSession
        sessionContexts.append(context)
        CatusshStore.shared.storeRecentIfNeeded(from: machine.id)
        completion(context)
    }

    @discardableResult
    public func createSession(withCommand command: SSHCommandReader) -> Context {
        let context = Context(command: command)
        sessionContexts.append(context)
        CatusshStore.shared.storeRecentIfNeeded(from: command)
        return context
    }

    @discardableResult
    public func createLocalSession() -> Context {
        let context = Context(localShell: true)
        sessionContexts.append(context)
        return context
    }

    public func sessionAlive(forContext contextId: Context.ID) -> Bool {
        !(sessionContexts.first { $0.id == contextId }?.closed ?? true)
    }

    public func closeSession(withMachineID machineId: RDMachine.ID) {
        if let index = sessionContexts.firstIndex(where: { $0.machine.id == machineId }) {
            let context = sessionContexts.remove(at: index)
            context.processShutdown()
            context.destroyedSession = true
            context.shell.destroyPermanently()
        }
    }

    public func closeSession(withContextID contextId: Context.ID) {
        if let index = sessionContexts.firstIndex(where: { $0.id == contextId }) {
            let context = sessionContexts.remove(at: index)
            context.processShutdown()
            context.destroyedSession = true
            context.shell.destroyPermanently()
        }
    }

    /// Alias used by the iOS app.
    public func end(for contextId: UUID) {
        closeSession(withContextID: contextId)
    }

    public func closeAll() {
        for context in sessionContexts {
            context.processShutdown()
            context.destroyedSession = true
            context.shell.destroyPermanently()
        }
        sessionContexts = []
    }

    public func moveSession(fromID: Context.ID, toID: Context.ID) {
        guard fromID != toID,
              let fromIndex = sessionContexts.firstIndex(where: { $0.id == fromID }),
              let toIndex = sessionContexts.firstIndex(where: { $0.id == toID })
        else { return }
        var updated = sessionContexts
        let item = updated.remove(at: fromIndex)
        updated.insert(item, at: toIndex)
        sessionContexts = updated
    }
}
