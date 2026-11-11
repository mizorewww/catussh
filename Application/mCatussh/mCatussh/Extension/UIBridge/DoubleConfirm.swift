//
//  DoubleConfirm.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/9.
//

import CatusshModule
import SwiftUI

extension UIBridge {
    /// ConfirmDialog: the title names the thing, one sentence of consequence,
    /// a verb on the confirming button and Cancel.
    static func requiresConfirmation(
        message: String,
        informative: String? = nil,
        confirmTitle: String = "Continue",
        destructive: Bool = true,
        /// Ask even when confirmations are turned off: for losing unsaved work.
        always: Bool = false,
        confirmation: @escaping (Bool) -> Void
    ) {
        if CatusshStore.shared.disableConformation, !always {
            confirmation(true)
            return
        }
        let alert = UIAlertController(title: message, message: informative, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in
            confirmation(false)
        }))
        alert.addAction(UIAlertAction(title: confirmTitle, style: destructive ? .destructive : .default, handler: { _ in
            confirmation(true)
        }))
        UIWindow.shutUpKeyWindow?.topMostViewController?.present(alert, animated: true, completion: nil)
    }
}
