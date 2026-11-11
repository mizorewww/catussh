//
//  TerminalContext.swift
//  mCatussh
//

import CatusshModule
import CatusshTerminal
import Combine
import SwiftUI
import UIKit

typealias TerminalContext = TerminalManager.Context

/// Which terminal screens are up, and which tab each shows in front. A
/// terminal opened as another tab of a server whose terminal is on screen
/// joins that screen's tabs instead of covering it with a new one.
@MainActor
final class TerminalFocus {
    static let shared = TerminalFocus()

    /// The tab to bring forward; screens showing one of its siblings do.
    let requests = PassthroughSubject<TerminalContext.ID, Never>()

    /// Screen token → the tab it shows in front.
    private var screens: [UUID: TerminalContext.ID] = [:]

    private init() {}

    func show(_ id: TerminalContext.ID, on screen: UUID) { screens[screen] = id }
    func remove(screen: UUID) { screens[screen] = nil }

    /// Whether a screen shows a tab of the same server or command as `context`.
    func isShowingSiblings(of context: TerminalContext) -> Bool {
        let siblings = Set(context.tabSiblings.map(\.id))
        return screens.values.contains { siblings.contains($0) }
    }

    func bringForward(_ context: TerminalContext) {
        requests.send(context.id)
    }
}

/// Bridges CatusshModule's shared terminal core to UIKit UI.
final class IOSTerminalUIHandler: TerminalUIHandler {
    func autoOpenInterface(_ context: CatusshModule.TerminalContext) {
        guard let context = context as? TerminalContext else { return }
        MainActor.assumeIsolated {
            if TerminalFocus.shared.isShowingSiblings(of: context) {
                TerminalFocus.shared.bringForward(context)
            }
            // On its server's page, which switches to the terminal.
            SessionNavigation.shared.reveal(terminal: context)
        }
    }
}
