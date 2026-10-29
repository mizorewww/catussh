//
//  ServerActions.swift
//  catussh (macOS)
//
//  The server context menu (Servers table, Home tiles) and the actions behind it.
//

import MachineStatusView
import CatusshDesign
import CatusshModule
import SwiftUI

enum ServerActions {
    @MainActor
    static func edit(_ machine: RDMachine.ID) {
        SheetPresenter.present { dismiss in
            ServerEditorSheet(machine: machine, close: dismiss)
        }
    }

    /// New Server, filled in from `template`.
    @MainActor
    static func create(from template: RDMachine) {
        SheetPresenter.present { dismiss in
            ServerEditorSheet(machine: nil, template: template, close: dismiss)
        }
    }

    static func duplicate(_ machine: RDMachine.ID) {
        let store = CatusshStore.shared
        let original = store.machineGroup[machine]
        guard original.isNotPlaceholder() else { return }
        UIBridge.requiresConfirmation(
            message: "Duplicate \(original.name)?",
            confirmTitle: "Duplicate"
        ) { confirmed in
            guard confirmed else { return }
            var copy = original
            copy.id = UUID()
            copy.name = original.name + " copy"
            store.machineGroup.insert(copy)
        }
    }

    @MainActor
    static func delete(_ machines: [RDMachine.ID]) {
        let store = CatusshStore.shared
        guard !machines.isEmpty else { return }
        let message = machines.count == 1
            ? "Delete \(store.machineGroup[machines[0]].name)?"
            : "Delete \(machines.count) servers?"
        UIBridge.requiresConfirmation(
            message: message,
            informative: "Port forwards through it stop working.",
            confirmTitle: "Delete",
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            for machine in machines {
                if let session = MonitorCenter.shared.session(for: machine) {
                    MonitorCenter.shared.end(session.id)
                }
                store.machineGroup.delete(machine)
            }
            store.cleanRecentIfNeeded()
        }
    }

    /// For a server whose keys were replaced: its next host key is saved.
    static func forgetHostKey(_ machine: RDMachine.ID) {
        let read = CatusshStore.shared.machineGroup[machine]
        guard read.isNotPlaceholder() else { return }
        UIBridge.requiresConfirmation(
            message: "Forget the host key of \(read.name)?",
            informative: "The key the server presents on the next connection is saved as its key. Do this only when you know its keys were replaced.",
            confirmTitle: "Forget"
        ) { confirmed in
            guard confirmed else { return }
            read.forgetHostKey()
        }
    }

    static func copyAddress(_ machine: RDMachine.ID) {
        let read = CatusshStore.shared.machineGroup[machine]
        UIBridge.sendPasteboard(str: "\(read.remoteAddress):\(read.remotePort)")
    }

    static func copyCommand(_ machine: RDMachine.ID) {
        UIBridge.sendPasteboard(str: CatusshStore.shared.machineGroup[machine].getCommand())
    }
}

/// The five ways into a server. Every surface that opens one (tiles, table rows,
/// context menus, the session switcher, the sidebar) uses these names, symbols and
/// descriptions, so a button means the same thing wherever it appears.
enum ServerTool: CaseIterable, Identifiable {
    case terminal
    case files
    case editor
    case monitor
    case desktop

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .editor: return "Editor"
        case .monitor: return "Monitor"
        case .desktop: return "Desktop"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: return "terminal"
        case .files: return "folder"
        case .editor: return "square.and.pencil"
        case .monitor: return "gauge.with.dots.needle.33percent"
        case .desktop: return "display"
        }
    }

    /// Tooltip: what the tool does, in a sentence.
    var help: String {
        switch self {
        case .terminal: return "Open an SSH terminal on this server"
        case .files: return "Browse, upload and download files over SFTP"
        case .editor: return "Edit text files on this server"
        case .monitor: return "Watch CPU, memory, disk and network usage"
        case .desktop: return "Open a VNC or UU Remote desktop"
        }
    }

    /// The tools a server can actually show. A UU Remote device has a
    /// terminal and a desktop through UU, and none of the SSH tools; a
    /// dead-end "Desktop" on a server without one would only error out.
    static func available(for machine: RDMachine) -> [ServerTool] {
        if machine.isUURemoteDevice { return [.terminal, .desktop] }
        return allCases.filter { $0 != .desktop || machine.hasRemoteDesktop }
    }

    /// Shows this tool for the server, reusing a session that is already open.
    @MainActor
    func show(_ machine: RDMachine.ID) {
        let router = AppRouter.shared
        switch self {
        case .terminal:
            if let existing = TerminalManager.shared.sessionContexts.first(where: { $0.remoteType == .machine && $0.machine.id == machine }) {
                router.route = .terminal(existing.id)
            } else {
                router.openTerminal(machine: machine)
            }
        case .files: router.openFileTransfer(machine: machine)
        case .editor: router.openEditor(machine: machine)
        case .monitor: router.openMonitor(machine: machine)
        case .desktop: router.openDesktop(machine: machine)
        }
    }
}

/// Terminal, Files, Monitor, Show in Menu Bar, Edit, Duplicate, Copy Address,
/// Copy SSH Command, Forget Host Key, Delete.
struct ServerContextMenu: View {
    let machine: RDMachine.ID
    /// False where the tools already sit beside the menu (a tile's ⋯ button).
    var includesTools = true

    var body: some View {
        if CatusshStore.shared.machineGroup[machine].isUURemoteDevice {
            uuDeviceItems
        } else {
            sshItems
        }
    }

    /// A UU Remote device has its desktop and nothing that needs SSH.
    @ViewBuilder private var uuDeviceItems: some View {
        Button {
            ServerTool.terminal.show(machine)
        } label: {
            Label("Open Terminal", systemImage: ServerTool.terminal.systemImage)
        }
        Button {
            AppRouter.shared.openTerminal(machine: machine)
        } label: {
            Label("New Terminal", systemImage: "plus.rectangle")
        }
        Divider()
        Button {
            AppRouter.shared.openDesktop(machine: machine)
        } label: {
            Label("Open Desktop", systemImage: ServerTool.desktop.systemImage)
        }
        Button {
            AppRouter.shared.openDesktop(machine: machine, viewOnly: true)
        } label: {
            Label("View Only", systemImage: "eye")
        }
        Divider()
        Button {
            ServerActions.edit(machine)
        } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button {
            UIBridge.sendPasteboard(str: CatusshStore.shared.machineGroup[machine].uuDeviceID)
        } label: {
            Label("Copy Device ID", systemImage: "doc.on.doc")
        }
    }

    @ViewBuilder private var sshItems: some View {
        let router = AppRouter.shared
        Group {
            if includesTools {
                Button {
                    ServerTool.terminal.show(machine)
                } label: {
                    Label("Open Terminal", systemImage: ServerTool.terminal.systemImage)
                }
                Button {
                    ServerTool.files.show(machine)
                } label: {
                    Label("Open Files", systemImage: ServerTool.files.systemImage)
                }
                Button {
                    ServerTool.editor.show(machine)
                } label: {
                    Label("Open Editor", systemImage: ServerTool.editor.systemImage)
                }
                Button {
                    ServerTool.monitor.show(machine)
                } label: {
                    Label("Open Monitor", systemImage: ServerTool.monitor.systemImage)
                }
                if CatusshStore.shared.machineGroup[machine].hasRemoteDesktop {
                    Button {
                        ServerTool.desktop.show(machine)
                    } label: {
                        Label("Open Desktop", systemImage: ServerTool.desktop.systemImage)
                    }
                }
            }
            Button {
                router.openTerminal(machine: machine)
            } label: {
                Label("New Terminal", systemImage: "plus.rectangle")
            }
            Button {
                router.showInMenuBar(machine: machine)
            } label: {
                Label("Show in Menu Bar", systemImage: "menubar.rectangle")
            }
            Divider()
            Button {
                ServerActions.edit(machine)
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            MoveToFolderMenu(machine: machine)
            Button {
                ServerActions.duplicate(machine)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button {
                ServerActions.copyAddress(machine)
            } label: {
                Label("Copy Address", systemImage: "doc.on.doc")
            }
            Button {
                ServerActions.copyCommand(machine)
            } label: {
                Label("Copy SSH Command", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Button {
                ServerActions.forgetHostKey(machine)
            } label: {
                Label("Forget Host Key…", systemImage: "key.slash")
            }
            Divider()
            Button(role: .destructive) {
                ServerActions.delete([machine])
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }
}

/// Live figures of a server while its monitor is open.
struct ServerLiveState {
    let cpu: Double?
    let memory: Double?

    @MainActor
    static func of(_ machine: RDMachine.ID) -> ServerLiveState {
        if let session = MonitorCenter.shared.session(for: machine),
           session.phase == .connected, session.status.hasData
        {
            return ServerLiveState(
                cpu: Double(session.status.processor.summary.sumUsed),
                memory: session.status.memoryUsedPercent
            )
        }
        return ServerLiveState(cpu: nil, memory: nil)
    }
}

/// Re-renders its content as the server's monitor or terminal changes.
struct ServerLiveReader<Content: View>: View {
    let machine: RDMachine.ID
    @ViewBuilder let content: (ServerLiveState) -> Content

    @ObservedObject private var monitors = MonitorCenter.shared
    @ObservedObject private var terminals = TerminalManager.shared

    var body: some View {
        if let session = monitors.session(for: machine) {
            SessionReader(session: session) { content(ServerLiveState.of(machine)) }
        } else {
            content(ServerLiveState.of(machine))
        }
    }

    private struct SessionReader<Inner: View>: View {
        @ObservedObject var session: MonitorSession
        @ViewBuilder let inner: () -> Inner
        var body: some View { inner() }
    }
}

/// Terminal · Files · Editor · Monitor (· Desktop when the server has a remote
/// desktop) for one server, centred in a session page's toolbar, so moving
/// between its views is one click from any of them.
struct ServerToolSwitcher: View {
    let machine: RDMachine.ID
    let current: ServerTool

    private var tools: [ServerTool] {
        ServerTool.available(for: CatusshStore.shared.machineGroup[machine])
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            RXToolbarSegmented(
                selection: current,
                options: tools.map { .init($0, $0.title, help: $0.help) }
            ) { $0.show(machine) }
        } else {
            Picker("View", selection: Binding(get: { current }, set: { $0.show(machine) })) {
                ForEach(tools) { tool in
                    Text(tool.title)
                        .help(tool.help)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Switch between this server's terminal, files, editor and monitor")
        }
    }
}

/// The server and tool a session page shows, for the switcher in its toolbar.
struct ServerToolSwitch: Equatable {
    let machine: RDMachine.ID
    let current: ServerTool
}

private struct ServerToolSwitchKey: EnvironmentKey {
    static let defaultValue: ServerToolSwitch? = nil
}

extension EnvironmentValues {
    var serverToolSwitch: ServerToolSwitch? {
        get { self[ServerToolSwitchKey.self] }
        set { self[ServerToolSwitchKey.self] = newValue }
    }
}

extension View {
    /// Places the `ServerToolSwitcher` in the centre of the window toolbar. The
    /// page's toolbar (`pageToolbar`) lays it out with the rest, so this goes
    /// outside it.
    func serverToolSwitcher(machine: RDMachine.ID?, current: ServerTool) -> some View {
        environment(\.serverToolSwitch, machine.map { ServerToolSwitch(machine: $0, current: current) })
    }
}
