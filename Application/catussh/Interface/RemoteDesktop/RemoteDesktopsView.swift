//
//  RemoteDesktopsView.swift
//  catussh (macOS)
//
//  Remote Desktop, a sidebar place: every server with a desktop (VNC or UU
//  Remote) and whether it is open, then the UU Remote account and the
//  desktop devices on it that can be opened or saved as servers.
//

import CatusshDesign
import CatusshModule
import SwiftUI

struct RemoteDesktopsView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var desktops = RemoteDesktopManager.shared
    @ObservedObject var account = UURemoteAccountStore.shared

    @State private var searchText = ""
    @State private var refreshing = false
    @State private var refreshError: String?

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

    /// Desktop devices on the account that no saved server is bound to.
    private var unsavedDevices: [UUDeviceInfo] {
        account.desktopDevices.filter { account.savedMachine(for: $0) == nil }
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
            ToolbarAction("UU Remote Account", systemImage: "person.crop.circle") { openAccount() }
        } header: {
            PageTitle("Remote Desktop", subtitle: "VNC, macOS Screen Sharing and NetEase UU Remote")
        } content: {
            VStack(alignment: .leading, spacing: RX.Space.s6) {
                serversCard
                uuCard
            }
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

    // MARK: - UU Remote

    private var uuCard: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            CardHead("UU Remote") {
                if account.isLoggedIn {
                    Button {
                        refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.rx(.plain, size: .small))
                    .disabled(refreshing)
                }
            }
            HStack(spacing: RX.Space.s3) {
                Image(systemName: account.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(account.isLoggedIn ? Color.rxAccent : Color.rxInkSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.isLoggedIn ? (account.nickname.isEmpty ? "Signed in" : account.nickname) : "Not signed in")
                        .font(.rxBody)
                        .foregroundStyle(.rxInk)
                    Text(account.isLoggedIn
                        ? "\(account.desktopDevices.count) desktop device(s) on this account"
                        : "Sign in with a QR code, SMS or a token to see your devices.")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                }
                Spacer()
                Button(account.isLoggedIn ? "Manage…" : "Sign In…") { openAccount() }
                    .buttonStyle(account.isLoggedIn ? .rx : .rxPrimary)
            }
            .padding(.horizontal, RX.Space.s3)
            .padding(.vertical, RX.Space.s2)
            if let refreshError {
                HelpText(refreshError, isError: true)
                    .padding(.horizontal, RX.Space.s3)
            }
            if account.isLoggedIn, !unsavedDevices.isEmpty {
                Divider().padding(.horizontal, RX.Space.s3)
                CapsLabel("Not saved as servers")
                    .padding(.horizontal, RX.Space.s3)
                    .padding(.top, RX.Space.s2)
                ForEach(unsavedDevices, id: \.deviceID) { device in
                    UUDeviceRow(device: device)
                }
            }
        }
        .rxCard(padding: RX.Space.s2)
        .task(id: account.isLoggedIn) {
            if account.isLoggedIn, account.devices.isEmpty { refresh() }
        }
    }

    private func refresh() {
        refreshing = true
        refreshError = nil
        Task { @MainActor in
            defer { refreshing = false }
            do {
                try await account.refreshDevices()
            } catch {
                refreshError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func openAccount() {
        SheetPresenter.present { dismiss in
            UURemoteAccountSheet(onConnectDesktop: { machineID in
                dismiss()
                AppRouter.shared.openDesktop(machine: machineID)
            }, close: dismiss)
        }
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
            let device = machine.uuDeviceAlias.isEmpty ? machine.uuDeviceID : machine.uuDeviceAlias
            return device.isEmpty ? "UU Remote" : "UU Remote · " + device
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

/// A UU Remote device with no server yet: Save as Server, or Connect, which
/// saves it and opens its desktop.
private struct UUDeviceRow: View {
    let device: UUDeviceInfo
    @ObservedObject var account = UURemoteAccountStore.shared
    @State private var hovered = false

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            StatusDot(device.isOnline ? .success : .off, size: .small)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.alias.isEmpty ? device.deviceID : device.alias)
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                Text("\(UUDeviceInfo.platformName(device.platform)) · \(device.isOnline ? "Online" : "Offline")")
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Save as Server") { _ = account.upsertMachine(for: device) }
                .buttonStyle(.rx(.plain, size: .small))
            Button("Connect") {
                AppRouter.shared.openDesktop(machine: account.upsertMachine(for: device).id)
            }
            .buttonStyle(.rx(size: .small))
            .disabled(!device.isOnline)
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableRowHeight)
        .rxRowBackground(selected: false, hovered: hovered)
        .onHover { hovered = $0 }
    }
}
