//
//  ServerEditorSheet.swift
//  catussh (macOS)
//
//  New / Edit Server: Name; Connect through; Address + Port; the Cloudflare
//  Access service token when connecting through it; Identity + Group; SFTP
//  start folder; Comment; Last banner (read-only, captured on connect).
//

import NSRemoteShell
import CatusshModule
import SwiftUI

struct ServerEditorSheet: View {
    /// nil creates a new server.
    let machine: RDMachine.ID?
    var close: (() -> Void)?

    @EnvironmentObject var store: CatusshStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var port = "22"
    @State private var transport: RDMachine.Transport = .direct
    @State private var serviceTokenID = ""
    @State private var serviceTokenSecret = ""
    @State private var identity: RDIdentity.ID?
    @State private var group = ""
    @State private var startFolder = "/"
    @State private var comment = ""
    @State private var banner = ""
    @State private var remoteDesktopProtocol: RDMachine.RemoteDesktopProtocolType = .none
    @State private var vncPort = "5900"
    @State private var vncPassword = ""
    @State private var vncUsername = ""
    @State private var vncOverSSH = false
    @State private var vncShared = true
    @State private var uuDeviceID = ""
    @State private var uuAssistID = ""
    @State private var uuAssistCode = ""

    @ObservedObject private var uuAccount = UURemoteAccountStore.shared

    @State private var connecting = false
    @State private var error: String?

    var isNew: Bool { machine == nil }
    var portIsValid: Bool { UInt16(port) != nil }
    var canSave: Bool { !address.trimmingCharacters(in: .whitespaces).isEmpty && portIsValid }

    var existingGroups: [String] {
        Set(store.machineGroup.machines.map(\.group)).filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        SheetScaffold(isNew ? "New Server" : "Edit Server") {
            VStack(alignment: .leading, spacing: 14) {
                RXField("Name") {
                    TextField(address.isEmpty ? "prod-web-01" : address, text: $name)
                        .textFieldStyle(.rx)
                }
                RXField("Connect through") {
                    RXPicker(
                        selection: $transport,
                        options: [
                            .init(.direct, "Direct (TCP)"),
                            .init(.cloudflareAccess, "Cloudflare Access"),
                            .init(.uuRemote, "NetEase UU Remote"),
                        ]
                    )
                }
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    RXField(transport == .cloudflareAccess ? "Access hostname" : transport == .uuRemote ? "Device ID" : "Address") {
                        TextField(transport == .cloudflareAccess ? "ssh.example.com" : transport == .uuRemote ? "UU Remote device id" : "Host name or IP address", text: $address)
                            .textFieldStyle(.rxMono)
                            .disableAutocorrection(true)
                    }
                    RXField("Port", error: portIsValid ? nil : "1–65535") {
                        TextField("22", text: $port)
                            .textFieldStyle(.rxMono)
                    }
                    .frame(width: 96)
                }
                if transport == .cloudflareAccess {
                    cloudflareFields
                } else if transport == .uuRemote {
                    HelpText("SSH, SFTP and Monitor on this server tunnel through the UU Remote session's port mapping — open the Desktop first so the tunnel is live.")
                }
                RXField("Remote Desktop") {
                    RXPicker(
                        selection: $remoteDesktopProtocol,
                        options: [
                            .init(RDMachine.RemoteDesktopProtocolType.none, "None"),
                            .init(.vnc, "VNC"),
                            .init(.uuRemote, "NetEase UU Remote"),
                        ]
                    )
                }
                if remoteDesktopProtocol == .vnc {
                    vncFields
                } else if remoteDesktopProtocol == .uuRemote {
                    uuFields
                }
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    RXField("Identity") {
                        RXPicker(
                            selection: $identity,
                            options: [.init(nil, "Automatic")] + store.identityGroup.identities.map { item in
                                .init(item.id, item.group.isEmpty ? item.username : "\(item.username) · \(item.group)")
                            }
                        )
                    }
                    RXField("Group") {
                        HStack(spacing: RX.Space.s1) {
                            TextField("Default", text: $group)
                                .textFieldStyle(.rx)
                            if !existingGroups.isEmpty {
                                Menu {
                                    ForEach(existingGroups, id: \.self) { item in
                                        Button(item) { group = item }
                                    }
                                } label: {
                                    Label("Existing Groups", systemImage: "chevron.down")
                                }
                                .menuStyle(.button)
                                .menuIndicator(.hidden)
                                .buttonStyle(.rx(iconOnly: true))
                                .fixedSize()
                                .help("Choose an existing group")
                            }
                        }
                    }
                }
                RXField("SFTP start folder") {
                    TextField("/", text: $startFolder)
                        .textFieldStyle(.rxMono)
                        .disableAutocorrection(true)
                }
                RXField("Comment") {
                    TextField("Optional", text: $comment)
                        .textFieldStyle(.rx)
                }
                if !isNew {
                    RXField("Last banner") {
                        RXValueField(banner, placeholder: "None", monospaced: true)
                    }
                }
                if let error {
                    HelpText(error, isError: true)
                }
            }
        } footer: {
            Button("Cancel", action: finish)
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Spacer()
            if connecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.rxBody)
                    .foregroundStyle(.rxInkSecondary)
            }
            if isNew {
                Button("Add", action: saveWithoutConnecting)
                    .buttonStyle(.rx)
                    .disabled(!canSave || connecting)
                    .help("Save the server without connecting")
                Button("Add and Connect", action: createAndConnect)
                    .buttonStyle(.rxPrimary)
                    .help("Check the connection, then save the server")
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || connecting)
            } else {
                Button("Save", action: saveWithoutConnecting)
                    .buttonStyle(.rxPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .frame(width: 520)
        .onAppear(perform: load)
    }

    /// The VNC listener details; reach it over an SSH local forward when
    /// the port only listens on the remote loopback.
    @ViewBuilder var vncFields: some View {
        HStack(alignment: .top, spacing: RX.Space.s4) {
            RXField("VNC port") {
                TextField("5900", text: $vncPort)
                    .textFieldStyle(.rxMono)
            }
            RXField("VNC password") {
                SecureField("Use identity password", text: $vncPassword)
                    .textFieldStyle(.rx)
            }
        }
        RXField("Mac user name") {
            TextField("Use identity user name", text: $vncUsername)
                .textFieldStyle(.rx)
                .disableAutocorrection(true)
        }
        HelpText("macOS Screen Sharing signs in with a Mac user name and password. Leave the VNC password empty to use the identity's; a VNC password alone uses VNC authentication.")
        HStack(spacing: RX.Space.s5) {
            Toggle("Tunnel over SSH", isOn: $vncOverSSH)
            Toggle("Shared session", isOn: $vncShared)
        }
        .toggleStyle(.switch)
    }

    /// Which UU Remote device draws the screen — pick one off the signed-in
    /// account or paste an id, or leave it to an assist code.
    @ViewBuilder var uuFields: some View {
        if !uuAccount.isLoggedIn {
            HelpText("Sign in to a UU Remote account to pick a device, or paste a device id / assist code below.")
        }
        if !uuAccount.desktopDevices.isEmpty {
            RXField("UU Remote device") {
                RXPicker(
                    selection: $uuDeviceID,
                    options: [.init("", "Manual / assist")]
                        + uuAccount.desktopDevices.map {
                            .init($0.deviceID, "\($0.alias.isEmpty ? $0.deviceID : $0.alias) · \(UUDeviceInfo.platformName($0.platform))")
                        }
                )
            }
        }
        if uuDeviceID.isEmpty {
            HStack(alignment: .top, spacing: RX.Space.s4) {
                RXField("Device ID") {
                    TextField("From the account's device list", text: $uuDeviceID)
                        .textFieldStyle(.rxMono)
                        .disableAutocorrection(true)
                }
            }
            HStack(alignment: .top, spacing: RX.Space.s4) {
                RXField("Assist connect ID") {
                    TextField("Optional", text: $uuAssistID)
                        .textFieldStyle(.rxMono)
                        .disableAutocorrection(true)
                }
                RXField("Assist code") {
                    SecureField("Optional", text: $uuAssistCode)
                        .textFieldStyle(.rxMono)
                }
            }
        }
        HStack {
            Button("UU Remote Account & Devices…") {
                SheetPresenter.present { dismiss in
                    UURemoteAccountSheet(onConnectDesktop: { machineID in
                        dismiss()
                        AppRouter.shared.openDesktop(machine: machineID)
                    }, close: dismiss)
                }
            }
            .buttonStyle(.rx)
            if uuAccount.isLoggedIn {
                Text("\(uuAccount.desktopDevices.count) desktop device(s)")
                    .font(.rxCaption)
                    .foregroundStyle(.rxInkSecondary)
            }
        }
    }

    /// What `cloudflared access ssh` would send: nothing for an application
    /// without an Access policy, a service token for one that asks for it.
    @ViewBuilder var cloudflareFields: some View {
        HStack(alignment: .top, spacing: RX.Space.s4) {
            RXField("Service token Client ID") {
                TextField("Optional", text: $serviceTokenID)
                    .textFieldStyle(.rxMono)
                    .disableAutocorrection(true)
            }
            RXField("Client Secret") {
                SecureField("Optional", text: $serviceTokenSecret)
                    .textFieldStyle(.rxMono)
            }
        }
        HelpText("Connects like ssh -o ProxyCommand='cloudflared access ssh --hostname %h', without cloudflared. Leave the service token empty when the application has no Access policy. The port only names the server's host key.")
    }

    /// The server as the form describes it, for checking the connection.
    var draft: RDMachine {
        var draft = RDMachine(remoteAddress: address.trimmingCharacters(in: .whitespaces), remotePort: port)
        apply(to: &draft)
        return draft
    }

    func apply(to target: inout RDMachine) {
        target.transport = transport
        let cloudflare = transport == .cloudflareAccess
        target.cloudflareServiceTokenID = cloudflare ? serviceTokenID.trimmingCharacters(in: .whitespaces) : ""
        target.cloudflareServiceTokenSecret = cloudflare ? serviceTokenSecret.trimmingCharacters(in: .whitespaces) : ""
        target.remoteDesktopProtocol = remoteDesktopProtocol
        target.vncPort = vncPort
        target.vncPassword = vncPassword
        target.vncUsername = vncUsername.trimmingCharacters(in: .whitespaces)
        target.vncOverSSH = vncOverSSH
        target.vncShared = vncShared
        target.uuDeviceID = uuDeviceID.trimmingCharacters(in: .whitespaces)
        target.uuAssistID = uuAssistID.trimmingCharacters(in: .whitespaces)
        target.uuAssistCode = uuAssistCode
    }

    func load() {
        guard let machine else { return }
        let read = store.machineGroup[machine]
        name = read.name
        address = read.remoteAddress
        port = read.remotePort
        group = read.group
        comment = read.comment
        startFolder = read.fileTransferLoginPath
        banner = read.lastBanner
        transport = read.transport
        serviceTokenID = read.cloudflareServiceTokenID
        serviceTokenSecret = read.cloudflareServiceTokenSecret
        remoteDesktopProtocol = read.remoteDesktopProtocol
        vncPort = read.vncPort
        vncPassword = read.vncPassword
        vncUsername = read.vncUsername
        vncOverSSH = read.vncOverSSH
        vncShared = read.vncShared
        uuDeviceID = read.uuDeviceID
        uuAssistID = read.uuAssistID
        uuAssistCode = read.uuAssistCode
        if let aid = read.associatedIdentity, let uid = UUID(uuidString: aid) {
            identity = uid
        }
    }

    func finish() {
        if let close { close() } else { dismiss() }
    }

    @discardableResult
    func save(banner capturedBanner: String? = nil, identity resolvedIdentity: RDIdentity.ID? = nil) -> RDMachine {
        // A new server has never been connected to; RXFormat shows the epoch as "Never".
        var target = machine.map { store.machineGroup[$0] } ?? RDMachine(lastConnection: Date(timeIntervalSince1970: 0))
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        target.remoteAddress = trimmedAddress
        target.remotePort = port
        target.name = name.isEmpty ? trimmedAddress : name
        target.group = group
        target.comment = comment
        target.fileTransferLoginPath = startFolder.isEmpty ? "/" : startFolder
        target.associatedIdentity = (resolvedIdentity ?? identity)?.uuidString
        apply(to: &target)
        if let capturedBanner {
            target.lastBanner = capturedBanner
            target.lastConnection = Date()
        }
        store.machineGroup.insert(target)
        return target
    }

    func saveWithoutConnecting() {
        save()
        finish()
    }

    /// Connects first; when no identity authenticates, asks for one.
    func createAndConnect() {
        error = nil
        connecting = true
        let host = address.trimmingCharacters(in: .whitespaces)
        let port = port
        let draft = draft
        let chosen = identity.map { store.identityGroup[$0] }
        let candidates = store.identityGroupForAutoAuth
        DispatchQueue.global().async {
            let shell = NSRemoteShell.configured(for: draft, timeout: CatusshStore.shared.timeoutNumber)
            shell.requestConnectAndWait()
            guard shell.isConnected else {
                let refusal = shell.connectFailureReason
                onMainThread {
                    connecting = false
                    error = refusal ?? "Could not reach \(host) on port \(port)."
                }
                return
            }
            var authenticatedWith: RDIdentity.ID?
            if let chosen {
                chosen.callAuthenticationWith(remote: shell)
                if shell.isAuthenticated { authenticatedWith = chosen.id }
            } else {
                for candidate in candidates {
                    if shell.isAuthenticated { break }
                    if !shell.isConnected { shell.requestConnectAndWait() }
                    candidate.callAuthenticationWith(remote: shell)
                    if shell.isAuthenticated { authenticatedWith = candidate.id }
                }
            }
            let banner = shell.remoteBanner ?? ""
            shell.requestDisconnectAndWait()
            onMainThread {
                connecting = false
                if let authenticatedWith {
                    finishCreation(banner: banner, identity: authenticatedWith)
                } else if chosen != nil {
                    error = "The selected identity could not sign in to \(host)."
                } else {
                    error = "No identity that authenticates automatically could sign in. Choose an identity."
                    IdentityPickerPanel.present { picked in
                        guard let picked else { return }
                        identity = picked
                        createAndConnect()
                    }
                }
            }
        }
    }

    func finishCreation(banner: String, identity: RDIdentity.ID) {
        let created = save(banner: banner, identity: identity)
        finish()
        onMainThread(delay: 0.2) {
            AppRouter.shared.openTerminal(machine: created.id)
        }
    }
}
