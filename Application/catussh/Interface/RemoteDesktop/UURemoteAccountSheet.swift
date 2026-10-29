//
//  UURemoteAccountSheet.swift
//  catussh (macOS)
//
//  The UU Remote account panel as a sheet: SheetScaffold chrome around the
//  shared CatusshModule view.
//

import CatusshDesign
import CatusshModule
import SwiftUI

struct UURemoteAccountSheet: View {
    /// Route "Connect" into the app's session navigation; nil just opens the
    /// session inside `RemoteDesktopManager`.
    var onConnectDesktop: ((RDMachine.ID) -> Void)?
    var close: (() -> Void)?

    var body: some View {
        SheetScaffold("UU Remote") {
            UURemoteAccountView(onConnectDesktop: onConnectDesktop)
        } footer: {
            Spacer()
            Button("Done") { close?() }
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 600, height: 520)
    }
}
