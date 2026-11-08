//
//  TerminalManager.swift
//  mCatussh
//

import CatusshModule
import SwiftUI

extension TerminalManager {
    func begin(for machineId: RDMachine.ID, force: Bool = false) {
        if !force {
            for terminal in terminals where terminal.machine.id == machineId {
                UIBridge.requiresConfirmation(
                    message: "Another terminal for this machine is already running"
                ) { confirmed in
                    guard confirmed else { return }
                    MainActor.assumeIsolated {
                        self.begin(for: machineId, force: true)
                    }
                }
                return
            }
        }
        let machine = CatusshStore.shared.machineGroup[machineId]
        guard machine.isNotPlaceholder() else {
            UIBridge.presentError(with: "Unknown Bad Data")
            return
        }
        createSession(withMachineObject: machine)
    }

    func begin(for command: SSHCommandReader, force: Bool = false) {
        if !force {
            for terminal in terminals where terminal.command == command {
                UIBridge.requiresConfirmation(
                    message: "Another terminal for this command is already running"
                ) { confirmed in
                    guard confirmed else { return }
                    MainActor.assumeIsolated {
                        self.begin(for: command, force: true)
                    }
                }
                return
            }
        }
        createSession(withCommand: command)
    }
}
