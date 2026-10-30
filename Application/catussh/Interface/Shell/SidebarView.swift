//
//  SidebarView.swift
//  catussh (macOS)
//
//  Home · Manage · Sessions (one row per server with open sessions; the page's
//  toolbar switches between its Terminal, Files and Monitor), with Settings
//  pinned to the bottom-left corner. Drawn to the measurements of an AppKit
//  source list, which UIKit's sidebar list does not share.
//

import MachineStatusView
import CatusshModule
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var router = AppRouter.shared
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared

    /// A place (Home, Servers…) or a server with open sessions. Selecting a
    /// server shows the tool it showed last; the toolbar switcher changes tools.
    enum Item: Hashable {
        case place(Route)
        case owner(SessionOwner)
    }

    var selection: Binding<Item?> {
        Binding(get: {
            if router.route.isSession {
                return router.owner(of: router.route).map(Item.owner)
            }
            return .place(router.route)
        }, set: { item in
            switch item {
            case let .place(route): router.route = route
            case let .owner(owner): router.show(owner)
            case nil: break
            }
        })
    }

    /// Changes whenever a session opens or closes; drives the row animation.
    private var sessionIDs: [UUID] {
        terminals.sessionContexts.map(\.id) + transfers.transfers.map(\.id)
            + monitors.sessions.map(\.id) + desktops.sessions.map(\.id)
    }

    var body: some View {
        let metrics = SidebarMetrics.current
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                place(.home, "Home", systemImage: "house")

                SidebarHeader("Manage")
                place(.servers, "Servers", systemImage: "server.rack", badge: store.machineGroup.count)
                place(.identities, "Identities", systemImage: "person.badge.key", badge: store.identityGroup.count)
                place(.snippets, "Snippets", systemImage: "chevron.left.forwardslash.chevron.right", badge: store.snippetGroup.count)
                place(.portForward, "Port Forward", systemImage: "arrow.left.arrow.right", badge: store.portForwardGroup.count)
                place(.desktops, "Remote Desktop", systemImage: "display", badge: store.machineGroup.machines.filter(\.hasRemoteDesktop).count)

                if !sessionIDs.isEmpty {
                    SidebarHeader("Sessions")
                    ForEach(router.openOwners, id: \.self) { owner in
                        SidebarRow(isSelected: selection.wrappedValue == .owner(owner)) {
                            selection.wrappedValue = .owner(owner)
                        } label: {
                            OwnerSidebarRow(owner: owner)
                        }
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, SidebarMetrics.inset)
        }
        .animation(.easeInOut(duration: 0.25), value: sessionIDs)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Settings stays pinned to the bottom-left corner, drawn exactly like
            // the rows above.
            place(.settings, "Settings", systemImage: "gearshape")
                .help("Settings (⌘,)")
                .padding(.horizontal, SidebarMetrics.inset)
                .frame(height: 48, alignment: .top)
        }
        .environment(\.sidebarMetrics, metrics)
    }

    private func place(_ route: Route, _ title: String, systemImage: String, badge: Int = 0) -> some View {
        SidebarRow(isSelected: selection.wrappedValue == .place(route)) {
            selection.wrappedValue = .place(route)
        } label: {
            SidebarLabel(title, systemImage: systemImage, badge: badge)
        }
    }
}

// MARK: - Rows

/// The sizes AppKit gives a source list, for each "Sidebar icon size" of System
/// Settings. UIKit's sidebar list is taller and highlights the selection in the
/// accent colour, so the rows are drawn here to the Mac's measurements.
struct SidebarMetrics: Equatable {
    var rowHeight: CGFloat
    var fontSize: CGFloat
    var iconSize: CGFloat
    /// From the leading edge of the row to the centre of its icon.
    var iconCenter: CGFloat
    /// From the leading edge of the row to its title.
    var titleLeading: CGFloat

    /// Rows stop this far from the edges of the sidebar.
    static let inset: CGFloat = 10

    static let small = SidebarMetrics(rowHeight: 25, fontSize: 10, iconSize: 15, iconCenter: 18.5, titleLeading: 36)
    static let medium = SidebarMetrics(rowHeight: 32, fontSize: 13, iconSize: 17, iconCenter: 19.25, titleLeading: 36.5)
    static let large = SidebarMetrics(rowHeight: 40, fontSize: 15, iconSize: 19.5, iconCenter: 20.25, titleLeading: 38.5)

    /// "Sidebar icon size" in System Settings › Appearance.
    static var current: SidebarMetrics {
        switch UserDefaults.standard.integer(forKey: "NSTableViewDefaultSizeMode") {
        case 1: return .small
        case 3: return .large
        default: return .medium
        }
    }
}

private struct SidebarMetricsKey: EnvironmentKey {
    static let defaultValue = SidebarMetrics.medium
}

private struct SidebarSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarMetrics: SidebarMetrics {
        get { self[SidebarMetricsKey.self] }
        set { self[SidebarMetricsKey.self] = newValue }
    }

    /// Whether the sidebar row a view sits in is the selected one.
    var isSidebarRowSelected: Bool {
        get { self[SidebarSelectedKey.self] }
        set { self[SidebarSelectedKey.self] = newValue }
    }
}

/// One selectable row: the grey rounded highlight of a Mac source list, selected
/// on mouse down like one.
private struct SidebarRow<Label: View>: View {
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.sidebarMetrics) private var metrics

    var body: some View {
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: metrics.rowHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.155))
                }
            }
            .contentShape(Rectangle())
            .environment(\.isSidebarRowSelected, isSelected)
            .onTapGesture(perform: select)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Icon in the accent colour, title, and a count at the trailing edge.
struct SidebarLabel<Title: View>: View {
    let systemImage: String
    let badge: Int
    let title: Title
    @Environment(\.sidebarMetrics) private var metrics
    @Environment(\.isSidebarRowSelected) private var isSelected

    init(systemImage: String, badge: Int = 0, @ViewBuilder title: () -> Title) {
        self.systemImage = systemImage
        self.badge = badge
        self.title = title()
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.iconSize))
                .foregroundStyle(.rxAccent)
                .frame(width: metrics.iconCenter * 2)
                .frame(width: metrics.titleLeading, alignment: .leading)
            title
                .font(.system(size: metrics.fontSize, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.primary.opacity(isSelected ? 0.5 : 0.4))
                    .padding(.trailing, 10)
            }
        }
    }
}

extension SidebarLabel where Title == Text {
    init(_ title: String, systemImage: String, badge: Int = 0) {
        self.init(systemImage: systemImage, badge: badge) { Text(title) }
    }
}

/// "Manage", "Sessions": the small grey heading over a group of rows.
private struct SidebarHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.26))
            .padding(.leading, 4)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .bottomLeading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A server with open sessions (or a Quick Connect terminal): its name, then
/// small symbols for the tools that are open.
private struct OwnerSidebarRow: View {
    let owner: SessionOwner
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var editors = EditorCenter.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared

    private var routes: [Route] { AppRouter.shared.routes(of: owner) }

    private var title: String {
        switch owner {
        case let .server(id):
            return store.machineGroup[id].name
        case let .command(id):
            return terminals.sessionContexts.first { $0.id == id }?.displayName ?? "Terminal"
        }
    }

    private var openTools: [ServerTool] {
        ServerTool.allCases.filter { tool in
            routes.contains { route in
                switch (tool, route) {
                case (.terminal, .terminal), (.files, .transfer), (.editor, .editor), (.monitor, .monitor), (.desktop, .desktop): return true
                default: return false
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            SidebarLabel(systemImage: { if case .command = owner { return "terminal" } else { return "server.rack" } }()) {
                RedactableText(title, redacted: store.machineRedacted == .all)
                    .truncationMode(.middle)
            }
            if case .server = owner {
                HStack(spacing: 3) {
                    ForEach(openTools) { tool in
                        Image(systemName: tool.systemImage)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.trailing, 10)
                .accessibilityHidden(true)
            }
        }
        .help(openTools.map(\.title).joined(separator: ", ") + " open")
        .contextMenu { menu }
    }

    @ViewBuilder var menu: some View {
        ForEach(routes, id: \.self) { route in
            switch route {
            case let .terminal(id):
                if let context = terminals.sessionContexts.first(where: { $0.id == id }) {
                    // Numbered as the tabs are, when there is more than one.
                    let tabs = context.tabSiblings
                    let number = tabs.count > 1 ? (tabs.firstIndex { $0.id == id }).map { " \($0 + 1)" } ?? "" : ""
                    if context.closed { Button("Reconnect Terminal\(number)") { context.reconnect() } }
                    Button("Close Tab\(number)") { TerminalSessionActions.close(context) }
                }
            case let .transfer(id):
                if let context = transfers.transfers.first(where: { $0.id == id }) {
                    Button("Close Files") { FileTransferSessionActions.close(context) }
                }
            case let .editor(id):
                if let workspace = editors.workspaces.first(where: { $0.id == id }) {
                    Button("Close Editor") { EditorSessionActions.close(workspace) }
                }
            case let .monitor(id):
                Button("Close Monitor") { MonitorCenter.shared.end(id) }
            case let .desktop(id):
                Button("Close Desktop") { RemoteDesktopManager.shared.end(id) }
            default:
                EmptyView()
            }
        }
        if routes.count > 1 {
            Divider()
            Button("Close All") {
                let unsaved = routes.contains { route in
                    guard case let .editor(id) = route else { return false }
                    return editors.workspaces.first { $0.id == id }?.hasUnsavedChanges ?? false
                }
                UIBridge.requiresConfirmation(
                    message: "Close everything open on \(title)?",
                    informative: unsaved ? "Unsaved changes in the editor will be lost." : nil,
                    confirmTitle: unsaved ? "Discard Changes and Close" : "Close All",
                    destructive: true,
                    always: unsaved
                ) { confirmed in
                    if confirmed { AppRouter.shared.closeAll(owner) }
                }
            }
        }
    }
}
