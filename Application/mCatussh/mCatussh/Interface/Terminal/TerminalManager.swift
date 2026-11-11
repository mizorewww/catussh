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
        createSession(withMachineObject: machine, askingToResume: true)
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

    /// A terminal to `machine`. A UU Remote device may have sessions to
    /// resume: they are offered first, as on the Mac.
    func createSession(
        withMachineObject machine: RDMachine,
        askingToResume: Bool,
        completion: @escaping (Context) -> Void = { _ in }
    ) {
        guard askingToResume, machine.isUURemoteDevice else {
            createSession(withMachineObject: machine, resuming: nil, completion: completion)
            return
        }
        UURemoteSessionPickerView.present(machine: machine) { choice in
            switch choice {
            case .new:
                self.createSession(withMachineObject: machine, resuming: nil, completion: completion)
            case let .resume(id):
                self.createSession(withMachineObject: machine, resuming: id, completion: completion)
            case nil:
                break
            }
        }
    }

    /// One more tab like `context`: the same server (asking to resume on a
    /// UU Remote device) or the same Quick Connect command.
    func openAnotherTab(like context: Context, completion: @escaping (Context) -> Void = { _ in }) {
        switch context.remoteType {
        case .machine:
            let machine = CatusshStore.shared.machineGroup[context.machine.id]
            guard machine.isNotPlaceholder() else {
                UIBridge.presentError(with: "This server's details could not be read.")
                return
            }
            createSession(withMachineObject: machine, askingToResume: true, completion: completion)
        case .command:
            if let command = context.command {
                completion(createSession(withCommand: command))
            }
        case .local:
            // No local shell on iOS.
            break
        }
    }
}

/// Closing terminal tabs, with the Mac's confirmation: a live session asks
/// first, except on a UU Remote device, whose session outlives its tab and
/// can be resumed.
enum TerminalSessionActions {
    @MainActor
    static func close(_ context: TerminalManager.Context, then: @escaping () -> Void = {}) {
        let manager = TerminalManager.shared
        let perform = {
            manager.closeSession(withContextID: context.id)
            then()
        }
        if manager.sessionAlive(forContext: context.id), !context.machine.isUURemoteDevice {
            UIBridge.requiresConfirmation(
                message: "Close this terminal tab?",
                informative: "Its session on \(context.displayName) ends.",
                confirmTitle: "Close Tab"
            ) { confirmed in
                if confirmed { MainActor.assumeIsolated { perform() } }
            }
        } else {
            perform()
        }
    }
}
