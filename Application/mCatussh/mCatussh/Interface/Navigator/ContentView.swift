//
//  ContentView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//
//  iPhone uses a tab bar: Home · Servers · Sessions · Snippets · More.
//  iPad keeps the macOS sidebar layout: the Mac's places (Remote Desktop
//  among them), then the open sessions, a server's terminal tabs as one row.
//

import MachineStatusView
import CatusshModule
import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                TabsView()
            } else {
                SidebarView()
            }
        }
        .tint(.rxAccent)
        .onAppear { SidebarNavigation.shared.isShown = horizontalSizeClass != .compact }
        .onChange(of: horizontalSizeClass) { SidebarNavigation.shared.isShown = $0 != .compact }
    }
}

/// What the iPad sidebar shows. While the sidebar is on screen, a session
/// that opens (a terminal, monitor, desktop, file transfer or editor) takes
/// the space beside it, as on the Mac, instead of a sheet over it; the tab
/// bar layout still presents them.
@MainActor
final class SidebarNavigation: ObservableObject {
    static let shared = SidebarNavigation()

    @Published var selection: SidebarView.Route? = .home
    var isShown = false
    /// The tab a server's terminal page shows in front when it opens.
    private(set) var terminalFront: [String: TerminalContext.ID] = [:]

    private init() {}

    /// Shows `route` beside the sidebar; false when there is no sidebar and
    /// the caller is to present the session itself.
    @discardableResult
    func open(_ route: SidebarView.Route) -> Bool {
        guard isShown else { return false }
        selection = route
        return true
    }

    func open(terminal context: TerminalContext) -> Bool {
        guard isShown else { return false }
        terminalFront[context.tabGroupKey] = context.id
        return open(.terminals(context.tabGroupKey))
    }
}

enum AppTab: Hashable {
    case home
    case servers
    case sessions
    case snippets
    case more
}

/// The iPhone tab bar.
struct TabsView: View {
    @State private var selection: AppTab = .home
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared
    @ObservedObject var editors = EditorCenter.shared

    var sessionCount: Int {
        terminals.terminals.count + monitors.sessions.count + transfers.transfers.count
            + desktops.sessions.count + editors.workspaces.count
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)
            NavigationStack { ServersView() }
                .tabItem { Label("Servers", systemImage: "server.rack") }
                .tag(AppTab.servers)
            NavigationStack { SessionsView() }
                .tabItem { Label("Sessions", systemImage: "terminal") }
                .badge(sessionCount)
                .tag(AppTab.sessions)
            NavigationStack { SnippetView() }
                .tabItem { Label("Snippets", systemImage: "chevron.left.forwardslash.chevron.right") }
                .tag(AppTab.snippets)
            NavigationStack { MoreView() }
                .tabItem { Label("More", systemImage: "ellipsis") }
                .tag(AppTab.more)
        }
    }
}

/// iPad: Home, Manage, Sessions, File Transfer, Settings.
struct SidebarView: View {
    enum Route: Hashable {
        case home
        case servers
        case identities
        case snippets
        case portForward
        /// Every server with a remote desktop, and the UU Remote account.
        case desktops
        case settings
        /// A server's (or Quick Connect command's) terminal tabs, by `tabGroupKey`.
        case terminals(String)
        case monitor(UUID)
        case transfer(UUID)
        /// A server's editor, by the id of the SFTP session it works over.
        case editor(UUID)
        case desktop(UUID)
    }

    @EnvironmentObject var store: CatusshStore
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared
    @ObservedObject var editors = EditorCenter.shared
    @ObservedObject var navigation = SidebarNavigation.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Label("Home", systemImage: "house").tag(Route.home)
                Section("Manage") {
                    row("Servers", "server.rack", .servers, badge: store.machineGroup.count)
                    row("Identities", "person", .identities, badge: store.identityGroup.count)
                    row("Snippets", "chevron.left.forwardslash.chevron.right", .snippets, badge: store.snippetGroup.count)
                    row("Port Forward", "arrow.right", .portForward, badge: store.portForwardGroup.count)
                    row("Remote Desktop", "display", .desktops, badge: store.machineGroup.machines.filter(\.hasRemoteDesktop).count)
                }
                if !terminals.terminals.isEmpty || !monitors.sessions.isEmpty || !desktops.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(terminals.tabGroups, id: \.first?.id) { tabs in
                            if let first = tabs.first {
                                Label(first.displayName, systemImage: "terminal")
                                    .badge(tabs.count > 1 ? tabs.count : 0)
                                    .tag(Route.terminals(first.tabGroupKey))
                                    .swipeActions {
                                        closeButton {
                                            for tab in tabs { TerminalManager.shared.end(for: tab.id) }
                                        }
                                    }
                            }
                        }
                        ForEach(monitors.sessions) { session in
                            Label(session.machine.name, systemImage: "waveform.path.ecg")
                                .tag(Route.monitor(session.id))
                                .swipeActions { closeButton { MonitorCenter.shared.end(session.id) } }
                        }
                        ForEach(desktops.sessions) { session in
                            Label(session.machine.name, systemImage: "display")
                                .tag(Route.desktop(session.id))
                                .swipeActions { closeButton { RemoteDesktopManager.shared.end(session.id) } }
                        }
                    }
                }
                if !transfers.transfers.isEmpty {
                    Section("File Transfer") {
                        ForEach(transfers.transfers) { context in
                            Label(context.machine.name, systemImage: "arrow.up.arrow.down")
                                .tag(Route.transfer(context.id))
                                .swipeActions { closeButton { FileTransferSessionActions.close(context) } }
                        }
                        ForEach(editors.workspaces) { workspace in
                            Label(workspace.context.machine.name, systemImage: "square.and.pencil")
                                .tag(Route.editor(workspace.id))
                                .swipeActions { closeButton { EditorCenter.shared.end(workspace.id) } }
                        }
                    }
                }
                Section {
                    Label("Settings", systemImage: "gearshape").tag(Route.settings)
                }
            }
            .navigationTitle("catussh")
            .scrollContentBackground(.hidden)
            .background(RXBackdrop().ignoresSafeArea())
        } detail: {
            NavigationStack {
                detail
            }
        }
    }

    func row(_ title: String, _ icon: String, _ route: Route, badge: Int) -> some View {
        Label(title, systemImage: icon)
            .badge(badge)
            .tag(route)
    }

    func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label("Close", systemImage: "xmark")
        }
    }

    @ViewBuilder var detail: some View {
        switch navigation.selection ?? .home {
        case .home: HomeView()
        case .servers: ServersView()
        case .identities: IdentityView()
        case .snippets: SnippetView()
        case .portForward: PortForwardView()
        case .desktops: RemoteDesktopsView()
        case .settings: SettingView()
        case let .terminals(key):
            // The tab just opened, else any tab of the group: the page
            // keeps track of the tab in front itself.
            let front = navigation.terminalFront[key]
            if let context = terminals.terminals.first(where: { $0.id == front && $0.tabGroupKey == key })
                ?? terminals.terminals.first(where: { $0.tabGroupKey == key })
            {
                TerminalView(context: context).id(key)
            } else {
                sessionGone
            }
        case let .editor(id):
            if let workspace = editors.workspaces.first(where: { $0.id == id }) {
                EditorWorkspaceView(workspace: workspace).id(id)
            } else {
                sessionGone
            }
        case let .monitor(id):
            if let session = monitors.session(withID: id) {
                MonitorView(session: session).id(id)
            } else {
                sessionGone
            }
        case let .desktop(id):
            if let session = desktops.session(withID: id) {
                // The screen takes the whole detail; its own bar closes it.
                RemoteDesktopStageView(session: session) {
                    RemoteDesktopManager.shared.end(session.id)
                }
                .toolbar(.hidden, for: .navigationBar)
                .id(id)
            } else {
                sessionGone
            }
        case let .transfer(id):
            if let context = transfers.transfers.first(where: { $0.id == id }) {
                FileTransferView(context: context).id(id)
            } else {
                sessionGone
            }
        }
    }

    /// The selection pointed at a session that is gone: show Home and drop
    /// the dangling selection.
    var sessionGone: some View {
        HomeView()
            .onAppear { navigation.selection = .home }
    }
}

/// Terminals, monitors, transfers, editors and desktops that are open. A
/// server's terminal tabs are one row; its page switches between them.
struct SessionsView: View {
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared
    @ObservedObject var editors = EditorCenter.shared

    var body: some View {
        Group {
            if terminals.terminals.isEmpty, monitors.sessions.isEmpty, transfers.transfers.isEmpty, desktops.sessions.isEmpty, editors.workspaces.isEmpty {
                EmptyStateView(
                    "No sessions",
                    systemImage: "terminal",
                    message: ""
                )
                .frame(maxHeight: .infinity)
                .background(RXBackdrop().ignoresSafeArea())
            } else {
                List {
                    if !terminals.terminals.isEmpty {
                        Section {
                            ForEach(terminals.tabGroups, id: \.first?.id) { tabs in
                                if let first = tabs.first {
                                    NavigationLink {
                                        TerminalView(context: first)
                                    } label: {
                                        SessionRow(title: first.displayName, systemImage: "terminal", count: tabs.count)
                                    }
                                    .swipeActions {
                                        Button("Close", role: .destructive) {
                                            for tab in tabs { TerminalManager.shared.end(for: tab.id) }
                                        }
                                    }
                                    .rxListRow()
                                }
                            }
                        } header: { RXSectionHeader("Terminals") }
                    }
                    if !monitors.sessions.isEmpty {
                        Section {
                            ForEach(monitors.sessions) { session in
                                NavigationLink {
                                    MonitorView(session: session)
                                } label: {
                                    MonitorSessionRow(session: session)
                                }
                                .swipeActions { Button("Close", role: .destructive) { MonitorCenter.shared.end(session.id) } }
                                .rxListRow()
                            }
                        } header: { RXSectionHeader("Monitors") }
                    }
                    if !desktops.sessions.isEmpty {
                        Section {
                            ForEach(desktops.sessions) { session in
                                NavigationLink {
                                    RemoteDesktopStageView(session: session)
                                } label: {
                                    SessionRow(title: session.machine.name, systemImage: "display")
                                }
                                .swipeActions { Button("Close", role: .destructive) { RemoteDesktopManager.shared.end(session.id) } }
                                .rxListRow()
                            }
                        } header: { RXSectionHeader("Desktops") }
                    }
                    if !transfers.transfers.isEmpty {
                        Section {
                            ForEach(transfers.transfers) { context in
                                NavigationLink {
                                    FileTransferView(context: context)
                                } label: {
                                    SessionRow(title: context.machine.name, systemImage: "arrow.up.arrow.down")
                                }
                                .swipeActions { Button("Close", role: .destructive) { FileTransferSessionActions.close(context) } }
                                .rxListRow()
                            }
                        } header: { RXSectionHeader("File Transfers") }
                    }
                    if !editors.workspaces.isEmpty {
                        Section {
                            ForEach(editors.workspaces) { workspace in
                                NavigationLink {
                                    EditorWorkspaceView(workspace: workspace)
                                } label: {
                                    SessionRow(title: workspace.context.machine.name, systemImage: "square.and.pencil", count: workspace.documents.count)
                                }
                                .swipeActions { Button("Close", role: .destructive) { EditorCenter.shared.end(workspace.id) } }
                                .rxListRow()
                            }
                        } header: { RXSectionHeader("Editors") }
                    }
                }
                .rxGroupedList()
            }
        }
        .navigationTitle("Sessions")
    }
}

struct SessionRow: View {
    let title: String
    let systemImage: String
    /// Tabs or files in the session, shown when more than one.
    var count = 1

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            Image(systemName: systemImage)
                .foregroundStyle(.rxInkSecondary)
                .frame(width: 22)
            Text(title)
                .font(.body)
                .foregroundStyle(.rxInk)
                .lineLimit(1)
            Spacer()
            if count > 1 {
                Text("\(count)")
                    .foregroundStyle(.rxInkSecondary)
                    .monospacedDigit()
            }
        }
    }
}

private struct MonitorSessionRow: View {
    @ObservedObject var session: MonitorSession
    var body: some View {
        SessionRow(title: session.machine.name, systemImage: "waveform.path.ecg")
    }
}

/// Identities, Port Forward, Remote Desktop, Settings, About, Logs, License.
struct MoreView: View {
    @EnvironmentObject var store: CatusshStore
    @State private var openUUAccount = false

    var body: some View {
        List {
            Section {
                NavigationLink { IdentityView() } label: {
                    moreRow("Identities", "person", count: store.identityGroup.count)
                }
                .rxListRow()
                NavigationLink { PortForwardView() } label: {
                    moreRow("Port Forward", "arrow.right", count: store.portForwardGroup.count)
                }
                .rxListRow()
                NavigationLink { RemoteDesktopsView() } label: {
                    moreRow("Remote Desktop", "display", count: store.machineGroup.machines.filter(\.hasRemoteDesktop).count)
                }
                .rxListRow()
                Button { openUUAccount = true } label: {
                    moreRow("UU Remote Account", "person.crop.circle")
                }
                .rxListRow()
            } header: { RXSectionHeader("Manage") }
            Section {
                NavigationLink { SettingView() } label: { moreRow("Settings", "gearshape") }
                    .rxListRow()
                NavigationLink { LogView() } label: { moreRow("Logs", "doc.text.magnifyingglass") }
                    .rxListRow()
                NavigationLink { LicenseView() } label: { moreRow("License", "doc.text") }
                    .rxListRow()
                Link(destination: URL(string: "https://github.com/mizorewww/catussh")!) {
                    moreRow("Source Code", "chevron.left.forwardslash.chevron.right")
                }
                .rxListRow()
            } header: { RXSectionHeader("App") } footer: {
                Text(appVersion)
            }
        }
        .rxGroupedList()
        .navigationTitle("More")
        .sheet(isPresented: $openUUAccount) {
            UURemoteAccountSheet()
        }
    }

    func moreRow(_ title: String, _ icon: String, count: Int? = nil) -> some View {
        HStack(spacing: RX.Space.s3) {
            Image(systemName: icon)
                .foregroundStyle(.rxAccent)
                .frame(width: 22)
            Text(title).foregroundStyle(.rxInk)
            Spacer()
            if let count {
                Text("\(count)").foregroundStyle(.rxInkSecondary).monospacedDigit()
            }
        }
    }
}

var appVersion: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    #if DEBUG
        return "catussh \(short) (\(build)) · Debug"
    #else
        return "catussh \(short) (\(build))"
    #endif
}
