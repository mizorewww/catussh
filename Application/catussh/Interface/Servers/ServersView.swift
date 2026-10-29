//
//  ServersView.swift
//  catussh (macOS)
//
//  All servers grouped, with search, redaction, Open Terminals and New Server.
//

import MachineStatusView
import CatusshDesign
import CatusshModule
import SwiftUI

struct ServersView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var router = AppRouter.shared

    @State private var searchText = ""
    @State private var selection: RDMachine.ID?

    var filtered: [RDMachine] {
        let machines = store.machineGroup.machines
        guard !searchText.isEmpty else { return machines }
        return machines.filter { $0.isQualifiedForSearch(text: searchText) }
    }

    /// The folders in order, Default last; empty folders only while not
    /// searching.
    var groups: [(name: String, machines: [RDMachine])] {
        let machines = filtered
        var names = store.folders.map(\.name)
        if machines.contains(where: { $0.group.isEmpty }) { names.append("") }
        return names.compactMap { name in
            let inside = machines.filter { $0.group == name }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if inside.isEmpty, !searchText.isEmpty { return nil }
            return (name, inside)
        }
    }

    var body: some View {
        PageScaffold(
            search: $searchText,
            searchPrompt: "Search servers",
            primary: ToolbarAction("New Server", systemImage: "plus", primary: true) {
                router.presentNewServer = true
            }
        ) {
        } trailing: {
            RXToolbarMenu(
                "New Folder",
                systemImage: "folder.badge.plus",
                items: [
                    RXToolbarMenuItem("New Folder…", systemImage: "folder.badge.plus", isOn: false) { FolderActions.newFolder() },
                    RXToolbarMenuItem("Link UU Remote Account…", systemImage: "link", isOn: false) { FolderActions.linkUURemote() },
                ]
            )
            .help("Make a folder, or fill one from a UU Remote account")
            RedactionMenu()
            Button { router.openTerminals() } label: {
                Label("Open Terminals…", systemImage: "rectangle.stack.badge.plus")
            }
            .help("Pick several servers and open a terminal on each")
            .disabled(store.machineGroup.machines.isEmpty)
        } header: {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                PageTitle("Servers")
                if store.machineRedacted != .none {
                    RedactionBanner()
                }
            }
        } content: {
            if store.machineGroup.machines.isEmpty, store.folders.isEmpty {
                EmptyStateView(
                    "No servers yet",
                    systemImage: "server.rack",
                    actionTitle: "New Server"
                ) {
                    router.presentNewServer = true
                }
                .rxCard()
            } else if filtered.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
                .rxCard()
            } else {
                ServersTable(groups: groups, selection: $selection)
            }
        }
        .background {
            // ⌘⌫ deletes the selected row.
            Button("Delete") {
                if let selection { ServerActions.delete([selection]) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selection == nil)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

/// None → Sensitive hides addresses → All hides names too.
struct RedactionMenu: View {
    @EnvironmentObject var store: CatusshStore

    var body: some View {
        RXToolbarMenu(
            "Privacy",
            systemImage: store.machineRedacted == .none ? "eye" : "eye.slash",
            items: [
                item("Show Everything", systemImage: "eye", level: .none),
                item("Hide Addresses", systemImage: "eye.slash", level: .sensitive),
                item("Hide Names and Addresses", systemImage: "eye.slash.fill", level: .all),
            ]
        )
        .help(store.machineRedacted.tooltip)
    }

    private func item(_ title: String, systemImage: String, level: RDMachine.RedactedLevel) -> RXToolbarMenuItem {
        RXToolbarMenuItem(title, systemImage: systemImage, isOn: store.machineRedacted == level) {
            store.machineRedacted = level
        }
    }
}

/// States that details are hidden and offers the way back.
struct RedactionBanner: View {
    @EnvironmentObject var store: CatusshStore

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.rxInkSecondary)
            Text(store.machineRedacted == .all ? "Names and addresses hidden" : "Addresses hidden")
                .font(.rxBody)
                .foregroundStyle(.rxInkSecondary)
            Button("Show") { store.machineRedacted = .none }
                .buttonStyle(.rx(size: .small))
        }
        .padding(.horizontal, 12)
        .frame(height: RX.controlHeight)
        .background(Capsule().fill(Color.rxPill))
    }
}

// MARK: - Table

private struct ServersTable: View {
    let groups: [(name: String, machines: [RDMachine])]
    @Binding var selection: RDMachine.ID?
    @EnvironmentObject var store: CatusshStore
    @State private var width: CGFloat = 900

    var body: some View {
        let columns = ServerColumns(width: width)
        VStack(spacing: 0) {
            header(columns)
            Hairline()
            ForEach(groups, id: \.name) { group in
                FolderHeaderRow(name: group.name, count: group.machines.count)
                    .transition(.opacity)
                if group.machines.isEmpty {
                    Text(store.folder(named: group.name)?.isLinked == true ? "No desktop devices on the account" : "Empty — move servers here from their menu")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                        .padding(.horizontal, RX.Space.s3)
                        .frame(maxWidth: .infinity, minHeight: RX.tableRowHeight, alignment: .leading)
                }
                ForEach(Array(group.machines.enumerated()), id: \.element.id) { index, machine in
                    ServerRow(machine: machine.id, columns: columns, selection: $selection)
                        .rxRise(index)
                        .transition(.opacity)
                }
            }
        }
        // Rows make room for a new server and close up after a deleted one.
        .animation(.rxMove, value: groups.flatMap { $0.machines.map(\.id) })
        .readWidth($width)
        .rxCard(padding: RX.Space.s2)
    }

    func header(_ columns: ServerColumns) -> some View {
        HStack(spacing: 0) {
            TableHeaderLabel("Name").frame(maxWidth: .infinity, alignment: .leading)
            TableHeaderLabel("Address").frame(width: columns.address)
            if columns.showIdentity { TableHeaderLabel("Identity").frame(width: columns.identity) }
            if columns.showCPU { TableHeaderLabel("CPU").frame(width: columns.cpu) }
            if columns.showLastUsed { TableHeaderLabel("Last used").frame(width: columns.lastUsed) }
            Color.clear.frame(width: columns.actions, height: 1)
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableHeaderHeight)
    }
}

struct ServerColumns {
    let address: CGFloat = 150
    let identity: CGFloat = 110
    let cpu: CGFloat = 110
    let lastUsed: CGFloat = 120
    let actions: CGFloat = 220
    let showIdentity: Bool
    let showCPU: Bool
    let showLastUsed: Bool

    init(width: CGFloat) {
        let base: CGFloat = 180 + 150 + 220 + 24
        showCPU = width > base + 110
        showIdentity = width > base + 110 + 110
        showLastUsed = width > base + 110 + 110 + 120
    }
}

private struct ServerRow: View {
    let machine: RDMachine.ID
    let columns: ServerColumns
    @Binding var selection: RDMachine.ID?

    @EnvironmentObject var store: CatusshStore
    @State private var hovered = false

    var body: some View {
        let read = store.machineGroup[machine]
        ServerLiveReader(machine: machine) { state in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    RedactableText(read.name, redacted: store.machineRedacted == .all)
                        .font(.rxBody)
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                    if !read.comment.isEmpty, store.machineRedacted == .none {
                        Text(read.comment)
                            .font(.rxHelp)
                            .foregroundStyle(.rxInkSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                RedactableText(read.isUURemoteDevice ? "UU Remote" : read.remoteAddress, redacted: store.machineRedacted != .none)
                    .font(.rxCode)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: columns.address, alignment: .leading)
                if columns.showIdentity {
                    Text(identityName(read))
                        .font(.rxBody)
                        .foregroundStyle(read.associatedIdentity == nil ? Color.rxInkSecondary : Color.rxInk)
                        .lineLimit(1)
                        .frame(width: columns.identity, alignment: .leading)
                }
                if columns.showCPU {
                    Group {
                        if let cpu = state.cpu {
                            HStack(spacing: RX.Space.s2) {
                                UsageBar(fraction: cpu / 100, height: 4)
                                    .frame(width: 48)
                                Text("\(RXFormat.percent(cpu))%")
                                    .font(.rxBody.monospacedDigit())
                            }
                        } else {
                            Text("—").foregroundStyle(.rxInkSecondary)
                        }
                    }
                    .frame(width: columns.cpu, alignment: .leading)
                }
                if columns.showLastUsed {
                    Text(RXFormat.relative(read.lastConnection))
                        .font(.rxBody)
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                        .frame(width: columns.lastUsed, alignment: .leading)
                }
                if read.isUURemoteDevice {
                    UUDeviceActions(machine: read)
                        .frame(width: columns.actions, alignment: .trailing)
                } else {
                HStack(spacing: RX.Space.s1) {
                    ForEach([ServerTool.files, .monitor]) { tool in
                        Button(tool.title) { tool.show(machine) }
                            .buttonStyle(.rx(.plain, size: .small))
                            .help(tool.help)
                    }
                    if CatusshStore.shared.machineGroup[machine].hasRemoteDesktop {
                        Button(ServerTool.desktop.title) { ServerTool.desktop.show(machine) }
                            .buttonStyle(.rx(.plain, size: .small))
                            .help(ServerTool.desktop.help)
                    }
                    Button(ServerTool.terminal.title) { ServerTool.terminal.show(machine) }
                        .buttonStyle(.rx(size: .small))
                        .help(ServerTool.terminal.help)
                }
                .frame(width: columns.actions, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableRowHeight)
        .rxRowBackground(selected: selection == machine, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded {
            AppRouter.shared.openTerminal(machine: machine)
        })
        .simultaneousGesture(TapGesture(count: 1).onEnded { selection = machine })
        .contextMenu { ServerContextMenu(machine: machine) }
    }

    func identityName(_ machine: RDMachine) -> String {
        guard let aid = machine.associatedIdentity, let uid = UUID(uuidString: aid) else { return "Automatic" }
        let identity = store.identityGroup[uid]
        return identity.username.isEmpty ? "Missing" : identity.username
    }
}

/// A UU Remote device's row actions: its desktop, or a view of it; the
/// device's online state from the last refresh.
private struct UUDeviceActions: View {
    let machine: RDMachine
    @ObservedObject private var account = UURemoteAccountStore.shared

    var body: some View {
        let device = account.devices.first { $0.deviceID == machine.uuDeviceID }
        HStack(spacing: RX.Space.s2) {
            if let device {
                StatusDot(device.isOnline ? .success : .off, size: .small)
                Text(device.isOnline ? "Online" : "Offline")
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
            }
            Button("View") { AppRouter.shared.openDesktop(machine: machine.id, viewOnly: true) }
                .buttonStyle(.rx(.plain, size: .small))
                .help("Watch the screen without controlling it")
            Button("Desktop") { AppRouter.shared.openDesktop(machine: machine.id) }
                .buttonStyle(.rx(.plain, size: .small))
                .help("Control this device's desktop")
            Button("Terminal") { ServerTool.terminal.show(machine.id) }
                .buttonStyle(.rx(size: .small))
                .help("Open the device's own shell through UU Remote")
        }
        // Signed out, the device cannot be reached; offline, nothing answers.
        .disabled(!account.isLoggedIn || device?.isOnline == false)
    }
}
