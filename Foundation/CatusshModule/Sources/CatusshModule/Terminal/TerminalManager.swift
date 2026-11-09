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

    public enum SplitOrientation: String, CaseIterable, Sendable {
        case horizontal
        case vertical
    }

    public struct SplitGroup: Identifiable, Equatable {
        public var id: UUID = .init()
        public var memberIDs: [Context.ID]
        public var orientation: SplitOrientation = .horizontal

        public init(id: UUID = .init(), memberIDs: [Context.ID], orientation: SplitOrientation = .horizontal) {
            self.id = id
            self.memberIDs = memberIDs
            self.orientation = orientation
        }
    }

    public final class Context: TerminalContext, @unchecked Sendable {
        private let surfaceBridge = TerminalSurfaceBridge()
        public var termInterface: CatusshTerminalView { surfaceBridge.termInterface }

        public init(machine: RDMachine, resuming uuSession: UInt32? = nil) {
            super.init(machine: machine, surface: surfaceBridge, resuming: uuSession)
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
    @Published public var splitGroups: [SplitGroup] = []

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
        let context = Context(machine: machine, resuming: uuSession)
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
            removeFromSplitGroups(context.id)
            context.processShutdown()
            context.destroyedSession = true
            context.shell.destroyPermanently()
        }
    }

    public func closeSession(withContextID contextId: Context.ID) {
        if let index = sessionContexts.firstIndex(where: { $0.id == contextId }) {
            let context = sessionContexts.remove(at: index)
            removeFromSplitGroups(context.id)
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
        splitGroups = []
    }

    public func splitGroup(containing id: Context.ID) -> SplitGroup? {
        splitGroups.first { $0.memberIDs.contains(id) }
    }

    public func groupSessions(
        anchorID: Context.ID,
        newID: Context.ID,
        orientation: SplitOrientation,
        insertBeforeAnchor: Bool = false
    ) {
        guard anchorID != newID else { return }
        removeFromSplitGroups(newID)

        if let idx = splitGroups.firstIndex(where: { $0.memberIDs.contains(anchorID) }) {
            var group = splitGroups[idx]
            group.orientation = orientation
            if let anchorPos = group.memberIDs.firstIndex(of: anchorID) {
                group.memberIDs.insert(newID, at: insertBeforeAnchor ? anchorPos : anchorPos + 1)
            } else {
                group.memberIDs.append(newID)
            }
            splitGroups[idx] = group
        } else {
            let members = insertBeforeAnchor ? [newID, anchorID] : [anchorID, newID]
            splitGroups.append(SplitGroup(memberIDs: members, orientation: orientation))
        }

        // Keep grouped tabs adjacent in `sessionContexts` in the exact order of `memberIDs`.
        if let group = splitGroup(containing: anchorID) {
            alignSessionOrder(for: group)
        }
    }

    public func setSplitOrientation(for contextID: Context.ID, orientation: SplitOrientation) {
        guard let idx = splitGroups.firstIndex(where: { $0.memberIDs.contains(contextID) }) else { return }
        splitGroups[idx].orientation = orientation
    }

    public func ungroupSession(_ id: Context.ID) {
        removeFromSplitGroups(id)
    }

    private func removeFromSplitGroups(_ id: Context.ID) {
        for idx in splitGroups.indices.reversed() {
            splitGroups[idx].memberIDs.removeAll { $0 == id }
            if splitGroups[idx].memberIDs.count < 2 {
                splitGroups.remove(at: idx)
            }
        }
    }

    private func alignSessionOrder(for group: SplitGroup) {
        guard let firstAnchorIdx = sessionContexts.firstIndex(where: { group.memberIDs.contains($0.id) }) else { return }
        let memberSet = Set(group.memberIDs)
        let orderedMembers = group.memberIDs.compactMap { id in sessionContexts.first { $0.id == id } }
        var remaining = sessionContexts
        remaining.removeAll { memberSet.contains($0.id) }
        let insertIndex = min(firstAnchorIdx, remaining.count)
        remaining.insert(contentsOf: orderedMembers, at: insertIndex)
        sessionContexts = remaining
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

        if let gIdx = splitGroups.firstIndex(where: { $0.memberIDs.contains(fromID) && $0.memberIDs.contains(toID) }),
           let mFrom = splitGroups[gIdx].memberIDs.firstIndex(of: fromID),
           let mTo = splitGroups[gIdx].memberIDs.firstIndex(of: toID)
        {
            let mItem = splitGroups[gIdx].memberIDs.remove(at: mFrom)
            splitGroups[gIdx].memberIDs.insert(mItem, at: mTo)
        }
    }
}
