//
//  MenubarTool.swift
//  catussh (macOS)
//

import CatusshModule
import Foundation

@MainActor
class MenubarTool {
    static let shared = MenubarTool()

    var statusItem: [MenubarStatusItem] = []
    var hasCat: Bool { !statusItem.isEmpty }

    private init() {}

    private static let persistedKey = "me.mizorewww.rayon.menubarMachines"

    private func persist() {
        let ids = statusItem.map(\.machine.id.uuidString)
        UserDefaults.standard.set(ids, forKey: Self.persistedKey)
        AppDelegate.shared?.updateActivationPolicy()
    }

    func restore() {
        let ids = UserDefaults.standard.stringArray(forKey: Self.persistedKey) ?? []
        for id in ids.compactMap(UUID.init(uuidString:)) {
            createRuncat(for: id, quiet: true)
        }
        persist()
    }

    struct ArgumentCompiler: Codable {
        let machine: RDMachine.ID
        let identity: RDIdentity.ID

        init(machine: RDMachine.ID, identity: RDIdentity.ID) {
            self.machine = machine
            self.identity = identity
        }

        @MainActor func createStatusItem() -> MenubarStatusItem? {
            let machine = CatusshStore.shared.machineGroup[machine]
            let identity = CatusshStore.shared.identityGroup[identity]
            guard machine.isNotPlaceholder(), !identity.username.isEmpty else {
                debugPrint("failed to create status item: malformed machine or identity")
                return nil
            }
            return .init(machine: machine, identity: identity)
        }
    }

    func createRuncat(for machineId: RDMachine.ID, quiet: Bool = false) {
        func fail(_ message: String) {
            if !quiet { UIBridge.presentError(with: message, delay: 0) }
        }
        for item in statusItem where item.machine.id == machineId {
            fail("This server is already in the menu bar")
            return
        }

        let machine = CatusshStore.shared.machineGroup[machineId]
        guard machine.isNotPlaceholder() else {
            fail("Could not add the server to the menu bar: its details are missing")
            return
        }
        guard machine.associatedIdentity != nil else {
            fail("To show a server in the menu bar, choose an identity for it first (Edit Server › Identity)")
            return
        }
        guard let identity = CatusshStore.shared.associatedIdentity(for: machine) else {
            fail("Could not add the server to the menu bar: its identity is missing")
            return
        }
        let compiler = ArgumentCompiler(machine: machine.id, identity: identity.id)
        guard let item = compiler.createStatusItem() else {
            return
        }
        statusItem.append(item)
        if !quiet { persist() }
    }

    #if DEBUG
        func showPreview() {
            let machine = RDMachine(remoteAddress: "203.0.113.10", remotePort: "22", name: "web-01")
            let item = MenubarStatusItem(machine: machine, identity: RDIdentity(), session: .preview(machine: machine))
            statusItem.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { item.togglePopover() }
        }
    #endif

    func item(withKey key: String) -> MenubarStatusItem? {
        statusItem.first { $0.key == key }
    }

    func remove(menubarItem: MenubarStatusItem.ID) {
        statusItem.removeAll { $0.id == menubarItem }
        persist()
    }
}
