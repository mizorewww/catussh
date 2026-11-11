//
//  UURemoteAccountSheet.swift
//  mCatussh
//
//  The UU Remote account panel as a sheet: navigation chrome around the
//  shared CatusshModule view. Connect opens the desktop, Terminal a terminal.
//

import CatusshModule
import SwiftUI

struct UURemoteAccountSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                UURemoteAccountView(onConnectDesktop: { machineID in
                    dismiss()
                    ServerActions.openDesktop(machineID)
                }, onOpenTerminal: { machineID in
                    dismiss()
                    TerminalManager.shared.begin(for: machineID)
                })
                .padding(RX.Space.s4)
            }
            .background(RXBackdrop().ignoresSafeArea())
            .navigationTitle("UU Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(.rxAccent)
    }
}
