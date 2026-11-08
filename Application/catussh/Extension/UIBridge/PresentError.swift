//
//  PresentError.swift
//  catussh (macOS)
//

import CatusshModule
import Foundation

extension UIBridge {
    static func presentAlert(with message: String) {
        onMainThread { MainActor.assumeIsolated { alert(message: message) } }
    }

    static func presentError(with message: String, delay: Double = 0) {
        debugPrint("<InterfaceError> \(message)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { alert(message: message) }
        }
    }
}
