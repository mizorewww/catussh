//
//  PortForwardView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/10.
//

import CatusshModule
import SwiftUI

struct PortForwardView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var backend = PortForwardBackend.shared
    @State private var openCreate = false

    var body: some View {
        Group {
            if store.portForwardGroup.forwards.isEmpty {
                EmptyStateView(
                    "No port forwards",
                    systemImage: "arrow.right",
                    actionTitle: "New Port Forward"
                ) {
                    openCreate = true
                }
                .frame(maxHeight: .infinity)
                .background(RXBackdrop().ignoresSafeArea())
            } else {
                List {
                    Section {
                        ForEach(store.portForwardGroup.forwards) { forward in
                            PortForwardRow(forward: forward)
                                .rxListRow()
                        }
                    } header: {
                        RXSectionHeader("\(backend.container.count) running")
                    }
                }
                .rxGroupedList()
            }
        }
        .navigationTitle("Port Forward")
        .toolbar {
            ToolbarItem {
                Button {
                    openCreate = true
                } label: {
                    Label("New Port Forward", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $openCreate) {
            NavigationStack { EditPortForwardView() }
        }
    }
}

private struct PortForwardRow: View {
    let forward: RDPortForward
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var backend = PortForwardBackend.shared
    @State private var openEdit = false

    var running: Bool { backend.sessionExists(withPortForwardID: forward.id) }

    var presentation: PortForwardPresentation {
        PortForwardPresentation(state: backend.lastStatus[forward.id], running: running)
    }

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RXTag(forward.forwardOrientation == .listenLocal ? "Listen local" : "Listen remote")
                    Text(verbatim: ":\(forward.bindPort)")
                        .font(.rxCode)
                        .foregroundStyle(.rxInk)
                }
                Text(verbatim: "\(forward.getMachineName() ?? "No server") → \(forward.targetHost):\(forward.targetPort)")
                    .font(.rxCode)
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
                if presentation.status == .danger {
                    Text(presentation.text)
                        .font(.caption)
                        .foregroundStyle(.rxDanger)
                }
            }
            Spacer()
            Toggle("Running", isOn: Binding(get: { running }, set: { on in
                if on {
                    backend.createSession(withPortForwardID: forward.id)
                } else {
                    backend.endSession(withPortForwardID: forward.id)
                }
            }))
            .labelsHidden()
            .tint(.rxAccent)
            .disabled(!forward.isValid())
        }
        .contentShape(Rectangle())
        .onTapGesture { if !running { openEdit = true } }
        .swipeActions {
            Button(role: .destructive) {
                UIBridge.requiresConfirmation(message: "Delete the forward on port \(forward.bindPort)?") { confirmed in
                    guard confirmed else { return }
                    backend.endSession(withPortForwardID: forward.id)
                    store.portForwardGroup.delete(forward.id)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                UIBridge.sendPasteboard(str: forward.getCommand() ?? "")
            } label: {
                Label("Copy Command", systemImage: "doc.on.doc")
            }
            Button {
                var copy = forward
                copy.id = .init()
                store.portForwardGroup.insert(copy)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        .sheet(isPresented: $openEdit) {
            NavigationStack { EditPortForwardView(requestPortForward: forward.id) }
        }
    }
}
