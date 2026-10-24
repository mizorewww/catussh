//
//  PortForwardView.swift
//  catussh (macOS)
//
//  Forwards: orientation, bind, through server, target, status and an on/off switch.
//

import CatusshModule
import SwiftUI

/// Header and rows share these, so the columns line up.
private enum ForwardColumns {
    static let orientation: CGFloat = 120
    static let bind: CGFloat = 90
    static let status: CGFloat = 200
    static let toggle: CGFloat = 52
}

struct PortForwardView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var backend = PortForwardBackend.shared

    @State private var searchText = ""
    @State private var selection: RDPortForward.ID?
    @State private var editor: EditorTarget?

    struct EditorTarget: Identifiable {
        let id = UUID()
        let forward: RDPortForward.ID?
    }

    var filtered: [RDPortForward] {
        let all = store.portForwardGroup.forwards
        guard !searchText.isEmpty else { return all }
        let key = searchText.lowercased()
        return all.filter {
            $0.targetHost.lowercased().contains(key)
                || String($0.targetPort).contains(key)
                || String($0.bindPort).contains(key)
                || ($0.getMachineName() ?? "").lowercased().contains(key)
        }
    }

    var body: some View {
        PageScaffold(
            search: $searchText,
            searchPrompt: "Search forwards",
            primary: ToolbarAction("New Port Forward", systemImage: "plus", primary: true) {
                editor = EditorTarget(forward: nil)
            },
            trailingMetrics: .single
        ) {
        } trailing: {
            ToolbarAction("Stop All", systemImage: "stop.circle") {
                for context in backend.container {
                    backend.endSession(withPortForwardID: context.info.id)
                }
            }
            .disabled(backend.container.isEmpty)
        } header: {
            PageTitle("Port Forward")
        } content: {
            if store.portForwardGroup.forwards.isEmpty {
                EmptyStateView(
                    "No port forwards",
                    systemImage: "arrow.right",
                    actionTitle: "New Port Forward"
                ) {
                    editor = EditorTarget(forward: nil)
                }
                .rxCard()
            } else if filtered.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
                    .rxCard()
            } else {
                table
            }
        }
        .sheet(item: $editor) { target in
            PortForwardEditorSheet(forward: target.forward) { editor = nil }
                .environmentObject(CatusshStore.shared)
        }
        .background {
            // ⌘⌫ deletes the selected row.
            Button("Delete") {
                if let selection { PortForwardActions.delete(selection) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selection == nil)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TableHeaderLabel("Orientation").frame(width: ForwardColumns.orientation)
                TableHeaderLabel("Bind").frame(width: ForwardColumns.bind)
                TableHeaderLabel("Through").frame(maxWidth: .infinity)
                TableHeaderLabel("Target").frame(maxWidth: .infinity)
                Color.clear.frame(width: ForwardColumns.status, height: 1)
                Color.clear.frame(width: ForwardColumns.toggle, height: 1)
            }
            .padding(.horizontal, RX.Space.s3)
            .frame(height: RX.tableHeaderHeight)
            Hairline()
            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, forward in
                PortForwardRow(forward: forward, selected: selection == forward.id) {
                    selection = forward.id
                } edit: {
                    editor = EditorTarget(forward: forward.id)
                }
                .rxRise(index)
                .transition(.opacity)
            }
        }
        .animation(.rxMove, value: filtered.map(\.id))
        .rxCard(padding: RX.Space.s2)
    }
}

private struct PortForwardRow: View {
    let forward: RDPortForward
    let selected: Bool
    let select: () -> Void
    let edit: () -> Void

    @EnvironmentObject var store: CatusshStore
    @ObservedObject var backend = PortForwardBackend.shared
    @State private var hovered = false

    var running: Bool { backend.sessionExists(withPortForwardID: forward.id) }

    var body: some View {
        let status = PortForwardPresentation(state: backend.lastStatus[forward.id], running: running)
        HStack(spacing: 0) {
            RXTag(forward.forwardOrientation == .listenLocal ? "Listen local" : "Listen remote")
                .frame(width: ForwardColumns.orientation, alignment: .leading)
            Text(verbatim: ":\(forward.bindPort)")
                .font(.rxCode)
                .foregroundStyle(.rxInk)
                .frame(width: ForwardColumns.bind, alignment: .leading)
            RedactableText(forward.getMachineName() ?? "No server", redacted: store.machineRedacted == .all)
                .font(.rxBody)
                .foregroundStyle(forward.usingMachine == nil ? Color.rxInkSecondary : Color.rxInk)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: forward.targetHost.isEmpty ? "—" : "\(forward.targetHost):\(forward.targetPort)")
                .font(.rxCode)
                .foregroundStyle(.rxInk)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(status.status == .danger ? status.text : "")
                .font(.rxBody)
                .foregroundStyle(.rxDanger)
                .lineLimit(1)
                .frame(width: ForwardColumns.status, alignment: .leading)
            Toggle("Running", isOn: Binding(get: { running }, set: { on in
                if on {
                    backend.createSession(withPortForwardID: forward.id)
                } else {
                    backend.endSession(withPortForwardID: forward.id)
                }
            }))
            .labelsHidden()
            .rxSwitchToggle()
            .controlSize(.small)
            .tint(.rxAccent)
            .disabled(!forward.isValid())
            .help(forward.isValid() ? (running ? "Stop" : "Start") : "Incomplete")
            .frame(width: ForwardColumns.toggle, alignment: .trailing)
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableRowHeight)
        .rxRowBackground(selected: selected, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { if !running { edit() } })
        .simultaneousGesture(TapGesture(count: 1).onEnded(select))
        .contextMenu {
            Button("Edit…", action: edit).disabled(running)
            Button("Duplicate") { PortForwardActions.duplicate(forward.id) }
            Button("Copy SSH Command") { UIBridge.sendPasteboard(str: forward.getCommand() ?? "") }
                .disabled(forward.getCommand() == nil)
            Divider()
            Button("Delete…", role: .destructive) { PortForwardActions.delete(forward.id) }
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
            confirmTitle: "Delete",
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            PortForwardBackend.shared.endSession(withPortForwardID: id)
            CatusshStore.shared.portForwardGroup.delete(id)
        }
    }
}

/// New / Edit Port Forward.
struct PortForwardEditorSheet: View {
    let forward: RDPortForward.ID?
    let onClose: () -> Void

    @EnvironmentObject var store: CatusshStore
    @State private var orientation: RDPortForward.ForwardOrientation = .listenLocal
    @State private var bindPort = ""
    @State private var machine: RDMachine.ID?
    @State private var targetHost = "127.0.0.1"
    @State private var targetPort = ""

    var draft: RDPortForward {
        var result = forward.map { store.portForwardGroup[$0] } ?? RDPortForward()
        result.forwardOrientation = orientation
        result.bindPort = Int(bindPort) ?? 0
        result.usingMachine = machine
        result.targetHost = targetHost.trimmingCharacters(in: .whitespaces)
        result.targetPort = Int(targetPort) ?? 0
        return result
    }

    var body: some View {
        SheetScaffold(
            forward == nil ? "New Port Forward" : "Edit Port Forward",
            lead: orientation == .listenLocal ? "This Mac :port → server → target" : "Server :port → this Mac → target"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                RXField("Orientation") {
                    RXSegmented(selection: $orientation, options: [
                        .init(.listenLocal, "Listen local"),
                        .init(.listenRemote, "Listen remote"),
                    ], caps: false, fullWidth: true)
                }
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    RXField("Bind port", error: bindPort.isEmpty || UInt16(bindPort) != nil ? nil : "1–65535") {
                        TextField("5433", text: $bindPort)
                            .textFieldStyle(.rxMono)
                    }
                    .frame(width: 120)
                    RXField("Forward through") {
                        RXPicker(
                            selection: $machine,
                            options: store.machineGroup.machines.map { .init(RDMachine.ID?.some($0.id), $0.name) },
                            placeholder: "Choose a server"
                        )
                    }
                }
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    RXField("Target host") {
                        TextField("127.0.0.1", text: $targetHost)
                            .textFieldStyle(.rxMono)
                            .disableAutocorrection(true)
                    }
                    RXField("Target port", error: targetPort.isEmpty || UInt16(targetPort) != nil ? nil : "1–65535") {
                        TextField("5432", text: $targetPort)
                            .textFieldStyle(.rxMono)
                    }
                    .frame(width: 120)
                }
                if let command = draft.getCommand(), draft.isValid() {
                    RXField("Equivalent command") {
                        CodeBlock(command)
                    }
                }
            }
        } footer: {
            Spacer()
            Button("Cancel", action: onClose)
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                store.portForwardGroup.insert(draft)
                onClose()
            }
            .buttonStyle(.rx)
            .disabled(!draft.isValid())
            Button("Save and Start") {
                let saved = draft
                store.portForwardGroup.insert(saved)
                PortForwardBackend.shared.createSession(withPortForwardID: saved.id)
                onClose()
            }
            .buttonStyle(.rxPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid())
        }
        .frame(width: 520)
        .onAppear {
            guard let forward else { return }
            let read = store.portForwardGroup[forward]
            orientation = read.forwardOrientation
            bindPort = read.bindPort > 0 ? String(read.bindPort) : ""
            machine = read.usingMachine
            targetHost = read.targetHost
            targetPort = read.targetPort > 0 ? String(read.targetPort) : ""
        }
    }
}
