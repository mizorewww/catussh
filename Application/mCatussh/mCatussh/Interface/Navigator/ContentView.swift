//
//  ContentView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//
//  iPhone uses a tab bar: Home · Servers · Sessions · Snippets · More.
//  iPad keeps the macOS sidebar layout.
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

    var sessionCount: Int {
        terminals.terminals.count + monitors.sessions.count + transfers.transfers.count + desktops.sessions.count
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
        case settings
        case terminal(UUID)
        case monitor(UUID)
        case transfer(UUID)
        case desktop(UUID)
    }

    @EnvironmentObject var store: CatusshStore
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared
    @State private var selection: Route? = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Home", systemImage: "house").tag(Route.home)
                Section("Manage") {
                    row("Servers", "server.rack", .servers, badge: store.machineGroup.count)
                    row("Identities", "person", .identities, badge: store.identityGroup.count)
                    row("Snippets", "chevron.left.forwardslash.chevron.right", .snippets, badge: store.snippetGroup.count)
                    row("Port Forward", "arrow.right", .portForward, badge: store.portForwardGroup.count)
                }
                if !terminals.terminals.isEmpty || !monitors.sessions.isEmpty || !desktops.sessions.isEmpty {
                    Section("Sessions") {
                        ForEach(terminals.terminals) { context in
                            Label(context.navigationTitle, systemImage: "terminal")
                                .tag(Route.terminal(context.id))
                                .swipeActions { closeButton { TerminalManager.shared.end(for: context.id) } }
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
                                .swipeActions { closeButton { FileTransferManager.shared.end(for: context.id) } }
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
        switch selection ?? .home {
        case .home: HomeView()
        case .servers: ServersView()
        case .identities: IdentityView()
        case .snippets: SnippetView()
        case .portForward: PortForwardView()
        case .settings: SettingView()
        case let .terminal(id):
            if let context = terminals.terminals.first(where: { $0.id == id }) {
                TerminalView(context: context).id(id)
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
                RemoteDesktopStageView(session: session).id(id)
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
            .onAppear { selection = .home }
    }
}

/// Terminals, monitors, transfers and desktops that are open.
struct SessionsView: View {
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared

    var body: some View {
        Group {
            if terminals.terminals.isEmpty, monitors.sessions.isEmpty, transfers.transfers.isEmpty, desktops.sessions.isEmpty {
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
                            ForEach(terminals.terminals) { context in
                                NavigationLink {
                                    TerminalView(context: context)
                                } label: {
                                    SessionRow(title: context.navigationTitle, systemImage: "terminal")
                                }
                                .swipeActions { Button("Close", role: .destructive) { TerminalManager.shared.end(for: context.id) } }
                                .rxListRow()
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
                                .swipeActions { Button("Close", role: .destructive) { FileTransferManager.shared.end(for: context.id) } }
                                .rxListRow()
                            }
                        } header: { RXSectionHeader("File Transfers") }
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
        }
    }
}

private struct MonitorSessionRow: View {
    @ObservedObject var session: MonitorSession
    var body: some View {
        SessionRow(title: session.machine.name, systemImage: "waveform.path.ecg")
    }
}

/// Identities, Port Forward, Settings, About, Logs, License.
struct MoreView: View {
    @EnvironmentObject var store: CatusshStore

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
