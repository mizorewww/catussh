//
//  AppRouter.swift
//  catussh (macOS)
//
//  The main window's navigation state and the actions that open sessions.
//

import Combine
import MachineStatusView
import CatusshModule
import CatusshTerminal
import SwiftUI

enum Route: Hashable {
    case home
    case servers
    case identities
    case snippets
    case portForward
    /// Every server with a remote desktop, and the UU Remote account.
    case desktops
    case settings
    case terminal(UUID)
    case monitor(UUID)
    case transfer(UUID)
    /// A server's editor, by the id of the SFTP session it works over.
    case editor(UUID)
    /// A server's remote desktop, by the RemoteDesktopSession id.
    case desktop(UUID)
}

/// The router and everything it publishes are main-thread state, like the
/// interface it drives.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var route: Route = .home {
        didSet {
            if !route.isSession {
                lastPlace = route
            } else if let owner = owner(of: route) {
                lastRoute[owner] = route
            }
        }
    }
    /// The page each server (or Quick Connect terminal) showed last, so its
    /// sidebar row returns to the same tool.
    private var lastRoute: [SessionOwner: Route] = [:]
    /// The last page that is not a session; closing a session returns here.
    private(set) var lastPlace: Route = .home
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// Presents the server editor for a new server from anywhere (menu, Home, Servers).
    @Published var presentNewServer = false
    /// Settings category to show when Settings opens.
    /// Settings follows this itself, so a change of category does not go
    /// through every view that watches the router.
    let settingsNavigation = ConfigNavigation(SettingsCategory.general)
    var settingsSelection: String {
        get { settingsNavigation.selection }
        set { settingsNavigation.go(newValue) }
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // When a session closes, leave its page.
        leaveWhenSessionEnds(TerminalManager.shared.$sessionContexts) {
            if case let .terminal(id) = $0 { return id }
            return nil
        }
        leaveWhenSessionEnds(MonitorCenter.shared.$sessions) {
            if case let .monitor(id) = $0 { return id }
            return nil
        }
        leaveWhenSessionEnds(FileTransferManager.shared.$transfers) {
            if case let .transfer(id) = $0 { return id }
            return nil
        }
        leaveWhenSessionEnds(EditorCenter.shared.$workspaces) {
            if case let .editor(id) = $0 { return id }
            return nil
        }
        leaveWhenSessionEnds(RemoteDesktopManager.shared.$sessions) {
            if case let .desktop(id) = $0 { return id }
            return nil
        }
    }

    /// Returns to the last non-session place once the open session page's id
    /// leaves the published list, meaning its session has closed.
    private func leaveWhenSessionEnds<Element: Identifiable>(
        _ publisher: Published<[Element]>.Publisher,
        id routeID: @escaping (Route) -> UUID?
    ) where Element.ID == UUID {
        publisher
            .sink { [weak self] sessions in
                guard let self, let id = routeID(self.route) else { return }
                if !sessions.contains(where: { $0.id == id }) { self.route = self.lastPlace }
            }
            .store(in: &cancellables)
    }

    private var opensAutomatically: Bool {
        CatusshStore.shared.openInterfaceAutomatically
    }

    // MARK: - Session actions

    func openTerminal(machine: RDMachine.ID) {
        TerminalManager.shared.createSession(withMachineID: machine) { [weak self] context in
            guard let self, self.opensAutomatically else { return }
            self.route = .terminal(context.id)
        }
    }

    func openTerminal(command: SSHCommandReader) {
        let context = TerminalManager.shared.createSession(withCommand: command)
        if opensAutomatically { route = .terminal(context.id) }
    }

    func openMonitor(machine: RDMachine.ID) {
        do {
            let session = try MonitorCenter.shared.begin(for: machine)
            route = .monitor(session.id)
        } catch {
            UIBridge.presentError(with: error.localizedDescription)
        }
    }

    /// Opens the server's remote desktop (VNC or UU Remote), reusing a live
    /// session. The session page reports "no remote desktop configured" on
    /// a server that has none, so callers do not have to check first.
    /// - Parameter viewOnly: watch the screen without sending input.
    func openDesktop(machine: RDMachine.ID, viewOnly: Bool = false) {
        let session = RemoteDesktopManager.shared.begin(for: machine)
        if viewOnly { session.viewOnly = true }
        route = .desktop(session.id)
    }

    func openFileTransfer(machine: RDMachine.ID) {
        let manager = FileTransferManager.shared
        if let existing = manager.transfers.first(where: { $0.machine.id == machine }) {
            route = .transfer(existing.id)
            return
        }
        manager.begin(for: machine)
        // Like Monitor, Files opens its page right away and connects in place.
        if let started = manager.transfers.last(where: { $0.machine.id == machine }) {
            route = .transfer(started.id)
        }
    }

    /// Shows the server's editor, connecting over SFTP if Files isn't open yet.
    @MainActor
    func openEditor(machine: RDMachine.ID) {
        let manager = FileTransferManager.shared
        if !manager.transfers.contains(where: { $0.machine.id == machine }) {
            manager.begin(for: machine)
        }
        if let context = manager.transfers.first(where: { $0.machine.id == machine }) {
            openEditor(context: context)
        }
    }

    /// Shows the editor of an SFTP session, with the file at `path` in front.
    @MainActor
    func openEditor(context: FileTransferContext, path: String? = nil) {
        let workspace = EditorCenter.shared.workspace(for: context)
        if let path { workspace.open(path: path) }
        route = .editor(context.id)
    }

    @MainActor
    func showInMenuBar(machine: RDMachine.ID) {
        MenubarTool.shared.createRuncat(for: machine)
    }

    /// Pick one or more servers, then open a terminal for each.
    @MainActor
    func openTerminals() {
        ServerPickerPanel.present(
            title: "Open Terminals",
            confirmTitle: "Open",
            allowsMany: true
        ) { machines in
            for machine in machines {
                TerminalManager.shared.createSession(withMachineID: machine) { _ in }
            }
            if let first = TerminalManager.shared.sessionContexts.last(where: { machines.contains($0.machine.id) }),
               self.opensAutomatically
            {
                self.route = .terminal(first.id)
            }
        }
    }

    // MARK: - Sessions by server

    /// The remote desktop whose page is showing, if one is.
    var desktopInFront: RemoteDesktopSession? {
        guard case let .desktop(id) = route else { return nil }
        return RemoteDesktopManager.shared.session(withID: id)
    }

    /// The terminal whose page is showing, if one is.
    var terminalInFront: TerminalManager.Context? {
        guard case let .terminal(id) = route else { return nil }
        return TerminalManager.shared.sessionContexts.first { $0.id == id }
    }

    /// Who a session page belongs to.
    func owner(of route: Route) -> SessionOwner? {
        switch route {
        case let .terminal(id):
            guard let context = TerminalManager.shared.sessionContexts.first(where: { $0.id == id }) else { return nil }
            return context.remoteType == .machine ? .server(context.machine.id) : .command(context.id)
        case let .transfer(id), let .editor(id):
            return FileTransferManager.shared.transfers.first { $0.id == id }.map { .server($0.machine.id) }
        case let .monitor(id):
            return MonitorCenter.shared.session(withID: id).map { .server($0.machine.id) }
        case let .desktop(id):
            return RemoteDesktopManager.shared.session(withID: id).map { .server($0.machine.id) }
        default:
            return nil
        }
    }

    /// Every open session page, terminals first, then files, editors, monitors and desktops.
    var sessionRoutes: [Route] {
        TerminalManager.shared.sessionContexts.map { .terminal($0.id) }
            + FileTransferManager.shared.transfers.map { .transfer($0.id) }
            + EditorCenter.shared.workspaces.map { .editor($0.id) }
            + MonitorCenter.shared.sessions.map { .monitor($0.id) }
            + RemoteDesktopManager.shared.sessions.map { .desktop($0.id) }
    }

    /// Servers and Quick Connect terminals with something open, in the order
    /// their first session opened.
    var openOwners: [SessionOwner] {
        var seen = Set<SessionOwner>()
        return sessionRoutes.compactMap(owner(of:)).filter { seen.insert($0).inserted }
    }

    func routes(of owner: SessionOwner) -> [Route] {
        sessionRoutes.filter { self.owner(of: $0) == owner }
    }

    /// Shows a server's sessions: the tool it showed last, else the first open one.
    func show(_ owner: SessionOwner) {
        let open = routes(of: owner)
        if let last = lastRoute[owner], open.contains(last) {
            route = last
        } else if let first = open.first {
            route = first
        }
    }

    /// Closes every session of a server or Quick Connect terminal.
    @MainActor
    func closeAll(_ owner: SessionOwner) {
        for route in routes(of: owner) {
            switch route {
            case let .terminal(id):
                if let context = TerminalManager.shared.sessionContexts.first(where: { $0.id == id }) {
                    TerminalManager.shared.closeSession(withContextID: context.id)
                }
            case let .transfer(id):
                FileTransferManager.shared.end(for: id)
            case let .editor(id):
                EditorCenter.shared.end(id)
            case let .monitor(id):
                MonitorCenter.shared.end(id)
            case let .desktop(id):
                RemoteDesktopManager.shared.end(id)
            default:
                break
            }
        }
    }

    /// ⌘W: closes the session page in front, as a browser closes its tab.
    /// The window itself never closes from here (it is the whole app); on a
    /// place, or with a sheet or alert up, the key does nothing.
    @MainActor
    func closeTabInFront() {
        guard CatusshUtil.topViewController()?.presentingViewController == nil,
              Mac.bridge?.isShowingSheet() != true
        else { return }
        switch route {
        case .terminal:
            if let terminal = terminalInFront { TerminalSessionActions.closeTab(terminal) }
        case let .transfer(id):
            if let context = FileTransferManager.shared.transfers.first(where: { $0.id == id }) {
                FileTransferSessionActions.close(context)
            }
        case let .editor(id):
            if let workspace = EditorCenter.shared.workspaces.first(where: { $0.id == id }) {
                EditorSessionActions.close(workspace)
            }
        case let .monitor(id):
            MonitorCenter.shared.end(id)
        case let .desktop(id):
            RemoteDesktopManager.shared.end(id)
        default:
            break
        }
    }

    func openSettings(_ category: String = SettingsCategory.general) {
        settingsSelection = category
        route = .settings
    }
}

/// What owns a group of session pages: a saved server, or one Quick Connect
/// terminal (which has no saved server to group under).
enum SessionOwner: Hashable {
    case server(RDMachine.ID)
    case command(UUID)
}

extension Route {
    var isSession: Bool {
        switch self {
        case .terminal, .monitor, .transfer, .editor, .desktop: return true
        default: return false
        }
    }
}

enum SettingsCategory {
    static let general = "general"
    static let about = "about"
}
