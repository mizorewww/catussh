//
//  DoubleConfirm.swift
//  catussh (macOS)
//

import CatusshModule
import SwiftUI

extension UIBridge {
    static func requiresConfirmation(
        message: String,
        informative: String? = nil,
        confirmTitle: String = "Continue",
        destructive: Bool = false,
        always: Bool = false,
        confirmation: @escaping (Bool) -> Void
    ) {
        nonisolated(unsafe) let confirmation = confirmation
        if CatusshStore.shared.disableConformation, !always {
            confirmation(true)
            return
        }
        onMainThread {
            MainActor.assumeIsolated {
                alert(
                    message: message,
                    informative: informative,
                    buttons: [confirmTitle, "Cancel"],
                    destructiveFirstButton: destructive,
                    textField: nil
                ) { button, _ in
                    confirmation(button == 0)
                }
            }
        }
    }
}

/// Bridges CatusshModule's shared file-transfer core to the Mac app's UI.
final class MacFileTransferUIHandler: FileTransferUIHandler {
    func presentError(_ message: String) {
        UIBridge.presentError(with: message)
    }

    func requiresConfirmation(_ message: String, completion: @escaping (Bool) -> Void) {
        UIBridge.requiresConfirmation(message: message, confirmation: completion)
    }

    func autoOpenInterface(_ context: FileTransferContext) {
        let id = context.id
        MainActor.assumeIsolated {
            if AppRouter.shared.route == .editor(id) { return }
            AppRouter.shared.route = .transfer(id)
        }
    }
}
