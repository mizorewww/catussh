//
//  PortForwardView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/10.
//
//  Forwards: kind and bind port, through server, target, status and an
//  on/off switch; search and Stop All.
//

import CatusshModule
import SwiftUI

struct PortForwardView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var backend = PortForwardBackend.shared
    @State private var openCreate = false
    @State private var searchKey = ""

    var filtered: [RDPortForward] {
        let all = store.portForwardGroup.forwards
        guard !searchKey.isEmpty else { return all }
        let key = searchKey.lowercased()
        return all.filter {
            $0.targetHost.lowercased().contains(key)
                || String($0.targetPort).contains(key)
                || String($0.bindPort).contains(key)
                || ($0.getMachineName() ?? "").lowercased().contains(key)
        }
    }

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
                        ForEach(filtered) { forward in
                            PortForwardRow(forward: forward)
                                .rxListRow()
                        }
                    } header: {
                        RXSectionHeader("\(backend.container.count) running")
                    }
                }
                .rxGroupedList()
                .searchable(text: $searchKey, prompt: "Search forwards")
            }
        }
        .navigationTitle("Port Forward")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    for context in backend.container {
                        backend.endSession(withPortForwardID: context.info.id)
                    }
                } label: {
                    Label("Stop All", systemImage: "stop.circle")
                }
                .disabled(backend.container.isEmpty)
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
                    RXTag(forward.forwardOrientation.label)
                    Text(verbatim: ":\(forward.bindPort)")
                        .font(.rxCode)
                        .foregroundStyle(.rxInk)
                }
                HStack(spacing: 4) {
                    RedactableText(forward.getMachineName() ?? "No server", redacted: store.machineRedacted == .all)
                    Text(verbatim: "→ \(forward.targetLabel)")
                }
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
                PortForwardActions.delete(forward.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                openEdit = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.rxAccent)
            .disabled(running)
        }
        .contextMenu {
            Button {
                openEdit = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(running)
            Button {
                PortForwardActions.duplicate(forward.id)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                UIBridge.sendPasteboard(str: forward.getCommand() ?? "")
            } label: {
                Label("Copy SSH Command", systemImage: "doc.on.doc")
            }
            .disabled(forward.getCommand() == nil)
            Divider()
            Button(role: .destructive) {
                PortForwardActions.delete(forward.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .sheet(isPresented: $openEdit) {
            NavigationStack { EditPortForwardView(requestPortForward: forward.id) }
        }
    }
}

enum PortForwardActions {
    static func duplicate(_ id: RDPortForward.ID) {
        var copy = CatusshStore.shared.portForwardGroup[id]
        copy.id = UUID()
        CatusshStore.shared.portForwardGroup.insert(copy)
    }

    @MainActor
    static func delete(_ id: RDPortForward.ID) {
        let forward = CatusshStore.shared.portForwardGroup[id]
        UIBridge.requiresConfirmation(
            message: "Delete the forward on port \(forward.bindPort)?",
            confirmTitle: "Delete"
        ) { confirmed in
            guard confirmed else { return }
            PortForwardBackend.shared.endSession(withPortForwardID: id)
            CatusshStore.shared.portForwardGroup.delete(id)
        }
    }
}
