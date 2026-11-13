//
//  ContentView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//
//  iPhone uses a tab bar: Home · Servers · Sessions · Snippets · More.
//  iPad keeps the macOS sidebar layout: the Mac's places (Remote Desktop
//  among them), then one row per server with something open, whose page
//  holds its terminal, files, editor, monitor and desktop.
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
        .onAppear { SessionNavigation.shared.isSidebarShown = horizontalSizeClass != .compact }
        .onChange(of: horizontalSizeClass) { SessionNavigation.shared.isSidebarShown = $0 != .compact }
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

    /// Servers with something open.
    var sessionCount: Int { SessionDirectory.owners.count }

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
        /// Every server with a remote desktop, and the UU Remote account.
        case desktops
        case settings
        /// A server's (or Quick Connect command's) page.
        case session(SessionOwner)
    }

    @EnvironmentObject var store: CatusshStore
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared
    @ObservedObject var editors = EditorCenter.shared
    @ObservedObject var navigation = SessionNavigation.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.selection) {
                Label("Home", systemImage: "house").tag(Route.home)
                Section("Manage") {
                    row("Servers", "server.rack", .servers, badge: store.machineGroup.count)
                    row("Identities", "person", .identities, badge: store.identityGroup.count)
                    row("Snippets", "chevron.left.forwardslash.chevron.right", .snippets, badge: store.snippetGroup.count)
                    row("Remote Desktop", "display", .desktops, badge: store.machineGroup.machines.filter(\.hasRemoteDesktop).count)
                }
                let owners = SessionDirectory.owners
                if !owners.isEmpty {
                    Section("Sessions") {
                        ForEach(owners, id: \.self) { owner in
                            SessionOwnerRow(owner: owner)
                                .tag(Route.session(owner))
                                .swipeActions { closeButton { SessionDirectory.closeAll(owner) } }
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
        case .desktops: RemoteDesktopsView()
        case .settings: SettingView()
        case let .session(owner):
            if SessionDirectory.isOpen(owner) {
                ServerWorkspaceView(owner: owner).id(owner)
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
                    Section {
                        ForEach(SessionDirectory.owners, id: \.self) { owner in
                            NavigationLink {
                                ServerWorkspaceView(owner: owner)
                            } label: {
                                SessionOwnerRow(owner: owner)
                            }
                            .swipeActions {
                                Button("Close", role: .destructive) { SessionDirectory.closeAll(owner) }
                            }
                            .rxListRow()
                        }
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

/// Identities, Remote Desktop, Settings, About, Logs, License.
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
