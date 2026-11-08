//
//  TerminalContext.swift
//  mCatussh
//

import CatusshModule
import CatusshTerminal
import SwiftUI
import UIKit

typealias TerminalContext = TerminalManager.Context

extension TerminalContext {
    struct DefaultPresent: View {
        let context: TerminalContext

        var body: some View {
            DefaultModalPresenter {
                TerminalView(context: context)
            }
        }
    }
}

/// Bridges CatusshModule's shared terminal core to UIKit UI.
final class IOSTerminalUIHandler: TerminalUIHandler {
    func autoOpenInterface(_ context: CatusshModule.TerminalContext) {
        guard let context = context as? TerminalContext else { return }
        let host = UIHostingController(
            rootView: TerminalContext.DefaultPresent(context: context)
        )
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .phone ? .fullScreen : .formSheet
        host.preferredContentSize = preferredPopOverSize
        PresentationQueue.present(next: host)
    }
}
