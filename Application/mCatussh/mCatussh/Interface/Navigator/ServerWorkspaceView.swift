//
//  ServerWorkspaceView.swift
//  mCatussh
//
//  A server's sessions are one page, as on the Mac: its terminal, files,
//  editor, monitor and desktop, switched between at the top. The iPad
//  sidebar lists one row per server, the iPhone's Sessions tab too; what
//  opens a session brings its server's page forward with that tool.
//

import CatusshModule
import MachineStatusView
import SwiftUI
import UIKit

/// What a group of sessions belongs to: a saved server, or the terminals of
/// one Quick Connect command, which has no saved server to group under.
enum SessionOwner: Hashable {
    case server(RDMachine.ID)
    /// A command's `tabGroupKey`.
    case command(String)

    init(_ context: TerminalContext) {
        self = context.remoteType == .machine ? .server(context.machine.id) : .command(context.tabGroupKey)
    }
}

/// The tools of a server's page.
enum ServerTool: CaseIterable, Identifiable {
    case terminal
    case files
    case editor
    case monitor
    case desktop

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .files: "Files"
        case .editor: "Editor"
        case .monitor: "Monitor"
        case .desktop: "Desktop"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal: "terminal"
        case .files: "folder"
        case .editor: "square.and.pencil"
        case .monitor: "gauge.with.dots.needle.33percent"
        case .desktop: "display"
        }
    }

    /// A "Desktop" on a server without one would only fail.
    static func available(for machine: RDMachine) -> [ServerTool] {
        allCases.filter { $0 != .desktop || machine.hasRemoteDesktop }
    }

    /// Opens this tool's session for the server, if it has none.
    @MainActor
    func open(_ machine: RDMachine.ID) {
        switch self {
        case .terminal:
            TerminalManager.shared.begin(for: machine)
        case .files:
            FileTransferManager.shared.begin(for: machine)
        case .editor:
            let transfers = FileTransferManager.shared
            if !transfers.transfers.contains(where: { $0.machine.id == machine }) {
                transfers.begin(for: machine)
            }
            if let context = transfers.transfers.first(where: { $0.machine.id == machine }) {
                _ = EditorCenter.shared.workspace(for: context)
            }
            // Files, opened for the editor to work over, brought itself
            // forward: the editor was asked for.
            SessionNavigation.shared.reveal(.server(machine), tool: .editor)
        case .monitor:
            do {
                _ = try MonitorCenter.shared.begin(for: machine)
            } catch {
                UIBridge.presentError(with: "Cannot open monitor")
            }
        case .desktop:
            _ = RemoteDesktopManager.shared.begin(for: machine)
        }
    }
}

/// Which server pages are where, and which tool each shows.
@MainActor
final class SessionNavigation: ObservableObject {
    static let shared = SessionNavigation()

    /// What the iPad sidebar shows.
    @Published var selection: SidebarView.Route? = .home
    /// The tool each server's page shows.
    @Published private(set) var tools: [RDMachine.ID: ServerTool] = [:]
    /// Whether the iPad sidebar is on screen; then a page opens beside it,
    /// else it is presented over what is there.
    var isSidebarShown = false
    /// The tab a server's terminal shows in front when it appears.
    private(set) var terminalFront: [String: TerminalContext.ID] = [:]
    /// Pages on screen, so a session of theirs switches them rather than
    /// opening another.
    private var onScreen: [SessionOwner: Int] = [:]

    private init() {}

    func tool(for machine: RDMachine.ID) -> ServerTool {
        if let tool = tools[machine] { return tool }
        // A page opened from its sidebar row: the first tool with a session.
        return ServerTool.allCases.first { SessionDirectory.hasSession(machine, $0) } ?? .terminal
    }

    /// The tool the user picked: shown, and its session opened if it has
    /// none yet.
    func pick(_ tool: ServerTool, for machine: RDMachine.ID) {
        tools[machine] = tool
        if !SessionDirectory.hasSession(machine, tool) { tool.open(machine) }
    }

    /// Brings a terminal forward on its server's page.
    func reveal(terminal context: TerminalContext) {
        terminalFront[context.tabGroupKey] = context.id
        reveal(SessionOwner(context), tool: .terminal)
    }

    /// Brings the owner's page forward with `tool`: beside the sidebar, on
    /// the page already up, or presented.
    func reveal(_ owner: SessionOwner, tool: ServerTool) {
        if case let .server(machine) = owner { tools[machine] = tool }
        if isSidebarShown {
            selection = .session(owner)
            return
        }
        guard onScreen[owner, default: 0] == 0 else { return }
        let host = UIHostingController(rootView: DefaultModalPresenter {
            ServerWorkspaceView(owner: owner)
        }.environmentObject(CatusshStore.shared))
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .phone ? .fullScreen : .formSheet
        host.preferredContentSize = preferredPopOverSize
        PresentationQueue.present(next: host)
    }

    fileprivate func appeared(_ owner: SessionOwner) { onScreen[owner, default: 0] += 1 }
    fileprivate func disappeared(_ owner: SessionOwner) { onScreen[owner, default: 1] -= 1 }
}

/// The open sessions, by server.
@MainActor
enum SessionDirectory {
    static func hasSession(_ machine: RDMachine.ID, _ tool: ServerTool) -> Bool {
        switch tool {
        case .terminal: TerminalManager.shared.terminals.contains { $0.remoteType == .machine && $0.machine.id == machine }
        case .files: FileTransferManager.shared.transfers.contains { $0.machine.id == machine }
        case .editor: EditorCenter.shared.workspaces.contains { $0.context.machine.id == machine }
        case .monitor: MonitorCenter.shared.session(for: machine) != nil
        case .desktop: RemoteDesktopManager.shared.session(for: machine) != nil
        }
    }

    /// Servers and Quick Connect commands with something open, in the order
    /// their first session opened.
    static var owners: [SessionOwner] {
        var all: [SessionOwner] = TerminalManager.shared.terminals.map(SessionOwner.init)
        all += FileTransferManager.shared.transfers.map { .server($0.machine.id) }
        all += EditorCenter.shared.workspaces.map { .server($0.context.machine.id) }
        all += MonitorCenter.shared.sessions.map { .server($0.machine.id) }
        all += RemoteDesktopManager.shared.sessions.map { .server($0.machine.id) }
        var seen = Set<SessionOwner>()
        return all.filter { seen.insert($0).inserted }
    }

    static func isOpen(_ owner: SessionOwner) -> Bool {
        switch owner {
        case let .server(machine): ServerTool.allCases.contains { hasSession(machine, $0) }
        case let .command(key): TerminalManager.shared.terminals.contains { $0.tabGroupKey == key }
        }
    }

    static func title(of owner: SessionOwner) -> String {
        switch owner {
        case let .server(machine):
            CatusshStore.shared.machineGroup[machine].name
        case let .command(key):
            TerminalManager.shared.terminals.first { $0.tabGroupKey == key }?.displayName ?? "Terminal"
        }
    }

    /// Sessions open for the owner, for a row's count.
    static func count(of owner: SessionOwner) -> Int {
        switch owner {
        case let .server(machine): ServerTool.allCases.filter { hasSession(machine, $0) }.count
        case let .command(key): TerminalManager.shared.terminals.filter { $0.tabGroupKey == key }.count
        }
    }

    /// Ends every session of the owner.
    static func closeAll(_ owner: SessionOwner) {
        switch owner {
        case let .command(key):
            for terminal in TerminalManager.shared.terminals where terminal.tabGroupKey == key {
                TerminalManager.shared.end(for: terminal.id)
            }
        case let .server(machine):
            for terminal in TerminalManager.shared.terminals where terminal.remoteType == .machine && terminal.machine.id == machine {
                TerminalManager.shared.end(for: terminal.id)
            }
            for workspace in EditorCenter.shared.workspaces where workspace.context.machine.id == machine {
                EditorCenter.shared.end(workspace.id)
            }
            for context in FileTransferManager.shared.transfers where context.machine.id == machine {
                FileTransferSessionActions.close(context)
            }
            if let session = MonitorCenter.shared.session(for: machine) { MonitorCenter.shared.end(session.id) }
            if let session = RemoteDesktopManager.shared.session(for: machine) { RemoteDesktopManager.shared.end(session.id) }
        }
    }
}

/// Whether a session view sits in a server's page, where closing it leaves
/// the page (and the server's other tools) up.
private struct InServerWorkspaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var inServerWorkspace: Bool {
        get { self[InServerWorkspaceKey.self] }
        set { self[InServerWorkspaceKey.self] = newValue }
    }
}

/// A server's page: the tool switcher, then the tool.
struct ServerWorkspaceView: View {
    let owner: SessionOwner

    @ObservedObject var navigation = SessionNavigation.shared
    @ObservedObject var store = CatusshStore.shared
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var editors = EditorCenter.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if case let .server(machine) = owner {
                let tools = ServerTool.available(for: store.machineGroup[machine])
                if tools.count > 1 { switcher(machine, tools) }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.inServerWorkspace, true)
        }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle(SessionDirectory.title(of: owner))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { navigation.appeared(owner) }
        .onDisappear { navigation.disappeared(owner) }
        // Everything of the server closed: the page goes too.
        .onChange(of: SessionDirectory.isOpen(owner)) { open in
            if !open { dismiss() }
        }
    }

    private func switcher(_ machine: RDMachine.ID, _ tools: [ServerTool]) -> some View {
        Picker("View", selection: Binding(
            get: { navigation.tool(for: machine) },
            set: { navigation.pick($0, for: machine) }
        )) {
            ForEach(tools) { tool in
                Text(tool.title).tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, RX.Space.s4)
        .padding(.vertical, RX.Space.s2)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(Color.rxSurface)
        .overlay(alignment: .bottom) { Color.rxHairline.frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        switch owner {
        case let .command(key):
            if let context = terminal(key) {
                TerminalView(context: context).id(key)
            } else {
                Color.clear
            }
        case let .server(machine):
            let tool = navigation.tool(for: machine)
            switch tool {
            case .terminal:
                if let context = terminal("server:\(machine.uuidString)") {
                    TerminalView(context: context).id(context.tabGroupKey)
                } else {
                    closed(tool, machine)
                }
            case .files:
                if let context = transfers.transfers.first(where: { $0.machine.id == machine }) {
                    FileTransferView(context: context).id(context.id)
                } else {
                    closed(tool, machine)
                }
            case .editor:
                if let workspace = editors.workspaces.first(where: { $0.context.machine.id == machine }) {
                    EditorWorkspaceView(workspace: workspace).id(workspace.id)
                } else {
                    closed(tool, machine)
                }
            case .monitor:
                if let session = monitors.session(for: machine) {
                    MonitorView(session: session).id(session.id)
                } else {
                    closed(tool, machine)
                }
            case .desktop:
                if let session = desktops.session(for: machine) {
                    RemoteDesktopStageView(session: session) {
                        RemoteDesktopManager.shared.end(session.id)
                    }
                    .id(session.id)
                } else {
                    closed(tool, machine)
                }
            }
        }
    }

    /// The tab just opened, else any tab of the group: the terminal page
    /// keeps track of the tab in front itself.
    private func terminal(_ key: String) -> TerminalContext? {
        let front = navigation.terminalFront[key]
        return terminals.terminals.first { $0.id == front && $0.tabGroupKey == key }
            ?? terminals.terminals.first { $0.tabGroupKey == key }
    }

    /// A tool whose session was closed: open it again from here.
    private func closed(_ tool: ServerTool, _ machine: RDMachine.ID) -> some View {
        VStack(spacing: RX.Space.s3) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.rxInkSecondary)
            Text("\(tool.title) is not open")
                .font(.headline)
                .foregroundStyle(.rxInk)
            Button("Open \(tool.title)") { tool.open(machine) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A row for an owner in the sidebar or the Sessions list.
struct SessionOwnerRow: View {
    let owner: SessionOwner

    var body: some View {
        SessionRow(
            title: SessionDirectory.title(of: owner),
            systemImage: { if case .server = owner { "server.rack" } else { "terminal" } }(),
            count: SessionDirectory.count(of: owner)
        )
    }
}
