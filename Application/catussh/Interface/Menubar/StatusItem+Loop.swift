//
//  StatusItem+Loop.swift
//  catussh (macOS)
//

import Combine
import CatusshModule
import MachineStatusView
import SwiftUI

extension MenubarStatusItem {
    @MainActor func observeSession() {
        session.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshFromSession() } }
            .store(in: &cancellables)

        CatusshStore.shared.$machineGroup
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] group in
                MainActor.assumeIsolated {
                    guard let self, !group[self.machine.id].isNotPlaceholder() else { return }
                    self.closeThisItem()
                }
            }
            .store(in: &cancellables)
    }

    @MainActor func refreshFromSession() {
        let speed: CatSpeed
        if session.phase != .connected || !session.status.hasData {
            speed = .broken
        } else {
            let cpu = session.status.processor.summary.sumUsed
            switch cpu {
            case ..<5: speed = .hang
            case ..<20: speed = .walk
            case ..<50: speed = .run
            case ..<80: speed = .fast
            default: speed = .light
            }
        }

        var title = ""
        if session.phase == .connected, session.status.hasData {
            let up = RXFormat.rateString(Double(session.status.totalTransmitPerSecond))
            let down = RXFormat.rateString(Double(session.status.totalReceivePerSecond))
            title = "↑ \(up)\n↓ \(down)"
        }
        updateDisplay(title: title, frameInterval: speed.rawValue)
    }
}
