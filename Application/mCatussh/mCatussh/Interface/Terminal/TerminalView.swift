//
//  TerminalView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//

import CatusshModule
import CatusshTerminal
import SwiftUI

struct TerminalView: View {
    @ObservedObject var context: TerminalContext

    @State var interfaceToken = UUID()

    @ObservedObject var store = CatusshStore.shared

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if context.interfaceToken == interfaceToken {
                GeometryReader { r in
                    context.termInterface
                        .onAppear {
                            context.termInterface.setTerminalFontSize(with: store.terminalFontSize, preferConfigured: true)
                        }
                        .onChange(of: store.terminalFontSize) { newValue in
                            context.termInterface.setTerminalFontSize(with: newValue)
                        }
                        .padding(r.size.width > 600 ? 8 : 2)
                }
            } else {
                EmptyStateView(
                    "Terminal moved to another window",
                    systemImage: "macwindow",
                    message: "This session is open in another window."
                )
            }
        }
        .background(RXBackdrop().ignoresSafeArea())
        .onAppear {
            debugPrint("set interface token \(interfaceToken)")
            context.interfaceToken = interfaceToken
        }
        .navigationTitle(context.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if context.closed {
                    Button {
                        DispatchQueue.global().async {
                            context.putInformation("[i] Reconnecting with the details from when this session started.")
                            context.putInformation("    If the server was edited, open a new terminal instead.")
                            context.processBootstrap()
                        }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) {
                    closeSession()
                } label: {
                    Label("Close Session", systemImage: "xmark.circle")
                }
            }
        }
    }

    func closeSession() {
        if context.closed {
            dismiss()
            TerminalManager.shared.end(for: context.id)
        } else {
            UIBridge.requiresConfirmation(
                message: "Close this session?",
                informative: "Anything running in it is stopped.",
                confirmTitle: "Close Session"
            ) { yes in
                if yes {
                    dismiss()
                    TerminalManager.shared.end(for: context.id)
                }
            }
        }
    }
}
