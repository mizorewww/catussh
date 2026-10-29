//
//  RemoteDesktopsView.swift
//  catussh (macOS)
//
//  Remote Desktop, a sidebar place: every server with a desktop (VNC or UU
//  Remote) and whether it is open, the screen-sharing Macs and VNC servers
//  nearby, and the UU Remote account whose devices fill a folder.
//

import CatusshDesign
import CatusshModule
import SwiftUI

struct RemoteDesktopsView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var desktops = RemoteDesktopManager.shared
    @ObservedObject var account = UURemoteAccountStore.shared
    @ObservedObject var nearby = VNCDiscovery.shared

    @State private var searchText = ""

    private var servers: [RDMachine] {
        let all = store.machineGroup.machines.filter(\.hasRemoteDesktop)
        let sorted = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return sorted }
        let key = searchText.lowercased()
        return sorted.filter {
            $0.name.lowercased().contains(key)
                || $0.remoteAddress.lowercased().contains(key)
                || $0.uuDeviceAlias.lowercased().contains(key)
        }
    }

    var body: some View {
        PageScaffold(
            search: $searchText,
            searchPrompt: "Search desktops",
            primary: ToolbarAction("New Server", systemImage: "plus", primary: true) {
                AppRouter.shared.presentNewServer = true
            }
        ) {
        } trailing: {
            ToolbarAction("UU Remote Account", systemImage: "person.crop.circle") { FolderActions.linkUURemote() }
        } header: {
            PageTitle("Remote Desktop", subtitle: "VNC, macOS Screen Sharing and NetEase UU Remote")
        } content: {
            VStack(alignment: .leading, spacing: RX.Space.s6) {
                serversCard
                nearbyCard
                uuCard
            }
            .onAppear { nearby.start() }
            .onDisappear { nearby.stop() }
        }
    }

    // MARK: - Servers

    @ViewBuilder private var serversCard: some View {
        if store.machineGroup.machines.allSatisfy({ !$0.hasRemoteDesktop }) {
            EmptyStateView(
                "No remote desktops",
                systemImage: "display",
                message: "Choose VNC or UU Remote under Remote Desktop when you edit a server.",
                actionTitle: "New Server"
            ) {
                AppRouter.shared.presentNewServer = true
            }
            .rxCard()
        } else if servers.isEmpty {
            EmptyStateView("No matches", systemImage: "magnifyingglass")
                .rxCard()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                CardHead("Servers")
                    .padding(.horizontal, RX.Space.s3)
                ForEach(servers) { machine in
                    // The session `openDesktop` would show: same server, same protocol.
                    DesktopServerRow(machine: machine, session: desktops.sessions.first {
                        $0.machine.id == machine.id && $0.protocolType == machine.remoteDesktopProtocol
                    })
                }
            }
            .rxCard(padding: RX.Space.s2)
        }
    }

    // MARK: - Nearby

    /// Bonjour `_rfb._tcp`: Macs with Screen Sharing on, and VNC servers.
    private var nearbyCard: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            CardHead("Nearby")
                .padding(.horizontal, RX.Space.s3)
            if let failure = nearby.failure {
                HelpText(failure, isError: true)
                    .padding(.horizontal, RX.Space.s3)
                    .padding(.bottom, RX.Space.s2)
            } else if nearby.hosts.isEmpty {
                HStack(spacing: RX.Space.s2) {
                    if nearby.isSearching { ProgressView().controlSize(.small) }
                    Text(nearby.isSearching
                        ? "Looking for Macs with Screen Sharing and VNC servers on this network…"
                        : "None found. On a Mac, turn on Screen Sharing in System Settings › General › Sharing.")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                }
                .padding(.horizontal, RX.Space.s3)
                .frame(height: RX.tableRowHeight)
            } else {
                ForEach(nearby.hosts) { host in
                    NearbyHostRow(host: host)
                }
            }
        }
        .rxCard(padding: RX.Space.s2)
    }

    // MARK: - UU Remote

    /// The account, and where its devices are: a folder on Servers.
    private var uuCard: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            CardHead("UU Remote")
                .padding(.horizontal, RX.Space.s3)
            HStack(spacing: RX.Space.s3) {
                Image(systemName: account.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(account.isLoggedIn ? Color.rxAccent : Color.rxInkSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.isLoggedIn ? (account.nickname.isEmpty ? "Signed in" : account.nickname) : "Not signed in")
                        .font(.rxBody)
                        .foregroundStyle(.rxInk)
                    Text(account.isLoggedIn
                        ? "\(account.desktopDevices.count) desktop device(s), in the \"\(account.folder(store: store)?.name ?? "UU Remote")\" folder on Servers"
                        : "Sign in, and the account's devices appear in a folder on Servers.")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                }
                Spacer()
                if account.isLoggedIn {
                    Button("Show in Servers") { AppRouter.shared.route = .servers }
                        .buttonStyle(.rx(.plain))
                }
                Button(account.isLoggedIn ? "Account…" : "Sign In…") { FolderActions.linkUURemote() }
                    .buttonStyle(account.isLoggedIn ? .rx : .rxPrimary)
            }
            .padding(.horizontal, RX.Space.s3)
            .padding(.vertical, RX.Space.s2)
        }
        .rxCard(padding: RX.Space.s2)
        .task(id: account.isLoggedIn) {
            if account.isLoggedIn { try? await account.refreshDevices() }
        }
    }
}

/// A screen-sharing host on the network: saved already (Connect), or Add,
/// which saves it and opens the editor for the account to sign in with.
private struct NearbyHostRow: View {
    let host: VNCDiscoveredHost
    @EnvironmentObject var store: CatusshStore
    @State private var hovered = false

    var body: some View {
        let saved = store.machineGroup.machines.first(where: host.matches)
        HStack(spacing: RX.Space.s3) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 15))
                .foregroundStyle(.rxAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                RedactableText("\(host.hostName):\(host.port)", redacted: store.machineRedacted != .none)
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let saved {
                Text("Saved as \(saved.name)")
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
                Button("Connect") { AppRouter.shared.openDesktop(machine: saved.id) }
                    .buttonStyle(.rx(size: .small))
            } else {
                // A Mac asks for an account: the editor is where it goes.
                Button("Add…") { ServerActions.create(from: host.makeMachine()) }
                .buttonStyle(.rx(size: .small))
                .help("Save as a VNC server and enter the Mac's user name and password")
            }
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableRowHeight)
        .rxRowBackground(selected: false, hovered: hovered)
        .onHover { hovered = $0 }
    }
}

/// A server with a desktop: name, protocol and target, whether it is open,
/// and Open / Close.
private struct DesktopServerRow: View {
    let machine: RDMachine
    /// The open session, if any; observed so the dot follows its phase.
    let session: RemoteDesktopSession?
    @EnvironmentObject var store: CatusshStore
    @State private var hovered = false

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            Image(systemName: machine.remoteDesktopProtocol == .uuRemote ? "globe.asia.australia" : "display")
                .font(.system(size: 15))
                .foregroundStyle(.rxAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                RedactableText(machine.name, redacted: store.machineRedacted == .all)
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                RedactableText(target, redacted: store.machineRedacted != .none)
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let session {
                SessionPhaseLabel(session: session)
            }
            Button("Edit") { ServerActions.edit(machine.id) }
                .buttonStyle(.rx(.plain, size: .small))
            if let session {
                Button("Close") { RemoteDesktopManager.shared.end(session.id) }
                    .buttonStyle(.rx(.plain, size: .small))
            }
            Button(session == nil ? "Connect" : "Show") { AppRouter.shared.openDesktop(machine: machine.id) }
                .buttonStyle(.rx(size: .small))
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableRowHeight)
        .rxRowBackground(selected: false, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .gesture(TapGesture(count: 2).onEnded { AppRouter.shared.openDesktop(machine: machine.id) })
        .contextMenu { ServerContextMenu(machine: machine.id) }
    }

    private var target: String {
        switch machine.remoteDesktopProtocol {
        case .vnc:
            var parts = ["VNC", machine.remoteAddress + ":" + machine.vncPort]
            if machine.vncOverSSH { parts.append("over SSH") }
            return parts.joined(separator: " · ")
        case .uuRemote:
            // The device's name only when the server's says something else.
            let device = machine.uuDeviceAlias.isEmpty ? machine.uuDeviceID : machine.uuDeviceAlias
            return device.isEmpty || device == machine.name ? "UU Remote" : "UU Remote · " + device
        case .none:
            return ""
        }
    }
}

/// The phase of an open desktop as a dot and a word.
private struct SessionPhaseLabel: View {
    @ObservedObject var session: RemoteDesktopSession

    var body: some View {
        HStack(spacing: RX.Space.s1) {
            StatusDot(status, size: .small)
            Text(title)
                .font(.rxHelp)
                .foregroundStyle(.rxInkSecondary)
        }
    }

    private var status: RXStatus {
        switch session.phase {
        case .connected: .success
        case .idle: .off
        case .connecting, .authenticating: .running
        case .closed: .warning
        case .failed: .danger
        }
    }

    private var title: String {
        switch session.phase {
        case .connected: session.viewOnly ? "Viewing" : "Connected"
        case .idle: "Idle"
        case .connecting, .authenticating: "Connecting"
        case .closed: "Closed"
        case .failed: "Failed"
        }
    }
}
