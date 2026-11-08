//
//  TerminalManager+App.swift
//  catussh (macOS)
//

import CatusshModule
import Foundation

extension TerminalManager {
    func createSession(
        withMachineObject machine: RDMachine,
        force: Bool,
        resuming uuSession: UInt32? = nil,
        completion: @escaping (Context) -> Void = { _ in }
    ) {
        let index = sessionContexts.firstIndex { $0.machine.id == machine.id }
        if index != nil, !force {
            UIBridge.requiresConfirmation(
                message: "\(machine.name) already has a terminal open",
                confirmTitle: "Open Another"
            ) { confirmed in
                if confirmed {
                    MainActor.assumeIsolated {
                        self.createSession(withMachineObject: machine, force: true, resuming: uuSession, completion: completion)
                    }
                }
            }
            return
        }
        createSession(withMachineObject: machine, resuming: uuSession, completion: completion)
    }

    func createSession(
        withMachineID machineId: RDMachine.ID,
        force: Bool = false,
        resuming uuSession: UInt32? = nil,
        completion: @escaping (Context) -> Void = { _ in }
    ) {
        let machine = CatusshStore.shared.machineGroup[machineId]
        guard machine.isNotPlaceholder() else {
            UIBridge.presentError(with: "This server's details could not be read.")
            return
        }
        createSession(withMachineObject: machine, force: force, resuming: uuSession, completion: completion)
    }
}
