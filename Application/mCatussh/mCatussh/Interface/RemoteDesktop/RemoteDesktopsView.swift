//
//  RemoteDesktopsView.swift
//  mCatussh
//
//  Remote Desktop, as on the Mac: every server with a desktop (VNC or UU
//  Remote) and whether it is open, the screen-sharing Macs and VNC servers
//  nearby, and the UU Remote account whose devices fill a folder.
//

import CatusshModule
import SwiftUI

struct RemoteDesktopsView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var desktops = RemoteDesktopManager.shared
    @ObservedObject var account = UURemoteAccountStore.shared
    @ObservedObject var nearby = VNCDiscovery.shared

    @State private var searchText = ""
    @State private var openAccount = false
    @State private var openNewServer = false
    @State private var editing: RDMachine.ID?

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
        List {
            serversSection
            nearbySection
            uuSection
        }
        .rxGroupedList()
        .searchable(text: $searchText, prompt: "Search desktops")
        .navigationTitle("Remote Desktop")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openAccount = true
                } label: {
                    Label("UU Remote Account", systemImage: "person.crop.circle")
                }
                Button {
                    openNewServer = true
                } label: {
                    Label("New Server", systemImage: "plus")
                }
            }
        }
        .onAppear { nearby.start() }
        .onDisappear { nearby.stop() }
        .task(id: account.isLoggedIn) {
            if account.isLoggedIn { try? await account.refreshDevices() }
        }
        .sheet(isPresented: $openAccount) {
            UURemoteAccountSheet()
        }
        .sheet(isPresented: $openNewServer) {
            NavigationStack { EditMachineView() }
        }
        .sheet(item: Binding(get: { editing.map(EditTarget.init) }, set: { editing = $0?.id })) { target in
            NavigationStack { EditMachineView(requestMachine: target.id) }
        }
    }

    private struct EditTarget: Identifiable { let id: RDMachine.ID }

    // MARK: - Servers

    @ViewBuilder private var serversSection: some View {
        Section {
            if store.machineGroup.machines.allSatisfy({ !$0.hasRemoteDesktop }) {
                EmptyStateView(
                    "No remote desktops",
                    systemImage: "display",
                    message: "Choose VNC or UU Remote under Remote Desktop when you edit a server.",
                    actionTitle: "New Server"
                ) {
                    openNewServer = true
                }
                .rxListRow()
            } else if servers.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
                    .rxListRow()
            } else {
                ForEach(servers) { machine in
                    // The session `openDesktop` would show: same server, same protocol.
                    DesktopServerRow(
                        machine: machine,
                        session: desktops.sessions.first {
                            $0.machine.id == machine.id && $0.protocolType == machine.remoteDesktopProtocol
                        },
                        edit: { editing = machine.id }
                    )
                    .rxListRow()
                }
            }
        } header: {
            RXSectionHeader("Servers")
        }
    }

    // MARK: - Nearby

    /// Bonjour `_rfb._tcp`: Macs with Screen Sharing on, and VNC servers.
    @ViewBuilder private var nearbySection: some View {
        Section {
            if let failure = nearby.failure {
                HelpText(failure, isError: true)
                    .rxListRow()
            } else if nearby.hosts.isEmpty {
                HStack(spacing: RX.Space.s2) {
                    if nearby.isSearching { ProgressView() }
                    Text(nearby.isSearching
                        ? "Looking for Macs with Screen Sharing and VNC servers on this network…"
                        : "None found. On a Mac, turn on Screen Sharing in System Settings › General › Sharing.")
                        .font(.footnote)
                        .foregroundStyle(.rxInkSecondary)
                }
                .rxListRow()
            } else {
                ForEach(nearby.hosts) { host in
                    NearbyHostRow(host: host) { editing = $0 }
                        .rxListRow()
                }
            }
        } header: {
            RXSectionHeader("Nearby")
        }
    }

    // MARK: - UU Remote

    /// The account, and where its devices are: a folder on Servers.
    private var uuSection: some View {
        Section {
            Button {
                openAccount = true
            } label: {
                HStack(spacing: RX.Space.s3) {
                    Image(systemName: account.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 26))
                        .foregroundStyle(account.isLoggedIn ? Color.rxAccent : Color.rxInkSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.isLoggedIn ? (account.nickname.isEmpty ? "Signed in" : account.nickname) : "Not signed in")
                            .foregroundStyle(.rxInk)
                        if let failure = account.refreshError, account.isLoggedIn {
                            Text(failure)
                                .font(.footnote)
                                .foregroundStyle(.rxDanger)
                        } else {
                            Text(account.isLoggedIn
                                ? "\(UURemoteAccountStore.deviceCount(account.desktopDevices.count)), in the \"\(account.folder(store: store)?.name ?? "UU Remote")\" folder on Servers"
                                : "Sign in, and the account's devices appear in a folder on Servers.")
                                .font(.footnote)
                                .foregroundStyle(.rxInkSecondary)
                        }
                    }
                    Spacer()
                    Text(account.isLoggedIn ? "Account…" : "Sign In…")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.rxAccent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rxListRow()
        } header: {
            RXSectionHeader("UU Remote")
        }
    }
}

/// A screen-sharing host on the network: saved already (Connect), or Add,
/// which saves it and opens the editor for the account to sign in with.
private struct NearbyHostRow: View {
    let host: VNCDiscoveredHost
    let edit: (RDMachine.ID) -> Void
    @EnvironmentObject var store: CatusshStore

    var body: some View {
        let saved = store.machineGroup.machines.first(where: host.matches)
        HStack(spacing: RX.Space.s3) {
            Image(systemName: "macbook.and.iphone")
                .foregroundStyle(.rxAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.displayName)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                RedactableText("\(host.hostName):\(host.port)", redacted: store.machineRedacted != .none)
                    .font(.footnote)
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
                if let saved {
                    Text(saved.name == host.displayName ? "Saved" : "Saved as \(saved.name)")
                        .font(.caption)
                        .foregroundStyle(.rxInkSecondary)
                }
            }
            Spacer()
            if let saved {
                Button("Connect") { ServerActions.openDesktop(saved.id) }
                    .buttonStyle(.rx(size: .small))
            } else {
                // A Mac asks for an account: the editor is where it goes.
                Button("Add…") {
                    let machine = host.makeMachine()
                    store.machineGroup.insert(machine)
                    edit(machine.id)
                }
                .buttonStyle(.rx(size: .small))
                .accessibilityHint("Save as a VNC server and enter the Mac's user name and password")
            }
        }
    }
}

/// A server with a desktop: name, protocol and target, whether it is open,
/// and Connect / Show; the server's actions on a long press.
private struct DesktopServerRow: View {
    let machine: RDMachine
    /// The open session, if any; observed so the dot follows its phase.
    let session: RemoteDesktopSession?
    let edit: () -> Void
    @ObservedObject private var account = UURemoteAccountStore.shared
    @EnvironmentObject var store: CatusshStore

    private var uuDevice: UUDeviceInfo? {
        account.devices.first { $0.deviceID == machine.uuDeviceID }
    }

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            Image(systemName: machine.remoteDesktopProtocol == .uuRemote ? "globe.asia.australia" : "display")
                .foregroundStyle(.rxAccent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                RedactableText(machine.name, redacted: store.machineRedacted == .all)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                RedactableText(machine.remoteDesktopTarget(uuDevice: uuDevice), redacted: store.machineRedacted != .none)
                    .font(.footnote)
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let session {
                    SessionPhaseLabel(session: session)
                }
            }
            Spacer()
            Button(session == nil ? "Connect" : "Show") { ServerActions.openDesktop(machine.id) }
                .buttonStyle(.rx(size: .small))
                // A UU device the account lists as offline has no desktop to show.
                .disabled(session == nil && uuDevice?.isOnline == false)
        }
        .contentShape(Rectangle())
        .swipeActions {
            if let session {
                Button("Close", role: .destructive) { RemoteDesktopManager.shared.end(session.id) }
            }
            Button(action: edit) {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.rxAccent)
        }
        .contextMenu {
            ServerMenuItems(machine: machine.id, edit: edit)
            if let session {
                Button(role: .destructive) { RemoteDesktopManager.shared.end(session.id) } label: {
                    Label("Close Desktop", systemImage: "xmark")
                }
            }
        }
    }
}

/// The phase of an open desktop as a dot and a word.
private struct SessionPhaseLabel: View {
    @ObservedObject var session: RemoteDesktopSession

    var body: some View {
        HStack(spacing: RX.Space.s1) {
            StatusDot(session.phaseStatus, size: .small)
            Text(session.phaseTitle)
                .font(.caption)
                .foregroundStyle(.rxInkSecondary)
        }
    }
}
