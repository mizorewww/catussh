//
//  EditMachineView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/3.
//
//  New / Edit Server: Name and Comment; Connect through (direct, a ProxyJump
//  bastion, Cloudflare Access or UU Remote); Address + Port; Remote Desktop;
//  Identity; Folder; SFTP start folder; Last banner (read-only). A new
//  server can be checked and connected before it is saved.
//

import CatusshModule
import SwiftUI

struct EditMachineView: View {
    @Environment(\.dismiss) private var dismiss

    let inEditWith: UUID?

    @State var remoteAddress: String
    @State var remotePort: String
    @State var name: String
    @State var group: String
    @State var comment: String
    @State var associatedIdentity: UUID?
    @State var transport: RDMachine.Transport
    @State var proxyJumpMachineID: RDMachine.ID?
    @State var serviceTokenID: String
    @State var serviceTokenSecret: String

    // Remote Desktop
    @State var remoteDesktopProtocol: RDMachine.RemoteDesktopProtocolType
    @State var vncPort: String
    @State var vncPassword: String
    @State var vncUsername: String
    @State var vncOverSSH: Bool
    @State var vncShared: Bool
    @State var uuDeviceID: String
    @State var uuAssistID: String
    @State var uuAssistCode: String
    @State var openUUAccount = false
    @ObservedObject var uuAccount = UURemoteAccountStore.shared

    // Extra
    @State var fileTransferLoginPath: String
    @State var banner: String

    @State var connecting = false
    @State var connectError: String?

    init(requestMachine: UUID? = nil) {
        inEditWith = requestMachine
        let read = requestMachine.map { CatusshStore.shared.machineGroup[$0] } ?? RDMachine()
        _remoteAddress = State(initialValue: read.remoteAddress)
        _remotePort = State(initialValue: read.remotePort.isEmpty ? "22" : read.remotePort)
        _name = State(initialValue: read.name)
        _group = State(initialValue: read.group)
        _comment = State(initialValue: read.comment)
        _associatedIdentity = State(initialValue: read.associatedIdentity.flatMap(UUID.init(uuidString:)))
        _transport = State(initialValue: read.transport)
        _proxyJumpMachineID = State(initialValue: read.proxyJumpMachineID.flatMap(UUID.init(uuidString:)))
        _serviceTokenID = State(initialValue: read.cloudflareServiceTokenID)
        _serviceTokenSecret = State(initialValue: read.cloudflareServiceTokenSecret)
        _remoteDesktopProtocol = State(initialValue: read.remoteDesktopProtocol)
        _vncPort = State(initialValue: read.vncPort)
        _vncPassword = State(initialValue: read.vncPassword)
        _vncUsername = State(initialValue: read.vncUsername)
        _vncOverSSH = State(initialValue: read.vncOverSSH)
        _vncShared = State(initialValue: read.vncShared)
        _uuDeviceID = State(initialValue: read.uuDeviceID)
        _uuAssistID = State(initialValue: read.uuAssistID)
        _uuAssistCode = State(initialValue: read.uuAssistCode)
        _fileTransferLoginPath = State(initialValue: read.fileTransferLoginPath)
        _banner = State(initialValue: read.lastBanner)
    }

    var isNew: Bool { inEditWith == nil }

    var trimmedAddress: String {
        remoteAddress.trimmingCharacters(in: .whitespaces)
    }

    var portIsValid: Bool { UInt16(remotePort) != nil && remotePort != "0" }

    var canSave: Bool {
        guard !trimmedAddress.isEmpty, portIsValid else { return false }
        if transport == .proxyJump { return proxyJumpMachineID != nil }
        return true
    }

    var jumpServerCandidates: [RDMachine] {
        CatusshStore.shared.machineGroup.machines
            .filter { $0.id != inEditWith && !$0.isUURemoteDevice }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var existingFolders: [String] {
        let store = CatusshStore.shared
        return Set(store.machineGroup.machines.map(\.group) + store.folders.map(\.name))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var identities: [RDIdentity] {
        CatusshStore.shared.identityGroup.identities
            .sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                TextField(trimmedAddress.isEmpty ? "Name" : trimmedAddress, text: $name)
                TextField("Comment", text: $comment)
            } header: {
                RXSectionHeader("Name")
            }

            Section {
                Picker("Connect through", selection: $transport) {
                    Text("Direct (TCP)").tag(RDMachine.Transport.direct)
                    Text("ProxyJump (Bastion)").tag(RDMachine.Transport.proxyJump)
                    Text("Cloudflare Access").tag(RDMachine.Transport.cloudflareAccess)
                    Text("NetEase UU Remote").tag(RDMachine.Transport.uuRemote)
                }
                if transport == .proxyJump {
                    Picker("Jump server", selection: $proxyJumpMachineID) {
                        Text(jumpServerCandidates.isEmpty ? "No other SSH servers saved" : "Choose…")
                            .tag(RDMachine.ID?.none)
                        ForEach(jumpServerCandidates) { item in
                            Text("\(item.name) (\(item.remoteAddress):\(item.remotePort))")
                                .tag(RDMachine.ID?.some(item.id))
                        }
                    }
                }
                TextField(transport == .cloudflareAccess ? "Access Hostname" : transport == .uuRemote ? "Device ID" : "Host Address", text: $remoteAddress)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                    .onChange(of: remoteAddress) { newValue in
                        let get = newValue.replacingOccurrences(of: "。", with: ".")
                        if remoteAddress != get { remoteAddress = get }
                    }
                TextField("Host Port", text: $remotePort)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numberPad)
            } header: {
                RXSectionHeader("Address")
            } footer: {
                if !portIsValid {
                    Text("The port is a number from 1 to 65535.")
                        .foregroundStyle(.rxDanger)
                } else if transport == .proxyJump {
                    Text("Reaches this server through an SSH tunnel opened on the jump server (ssh -J).")
                }
            }

            if transport == .cloudflareAccess {
                Section {
                    TextField("Client ID (optional)", text: $serviceTokenID)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    SecureField("Client Secret (optional)", text: $serviceTokenSecret)
                } header: {
                    RXSectionHeader("Cloudflare Access Service Token")
                } footer: {
                    Text("Connects like ssh -o ProxyCommand='cloudflared access ssh --hostname %h'. Leave the service token empty when the application has no Access policy. The port only names the server's host key.")
                }
            }

            if transport == .uuRemote {
                Section {
                } header: {
                    RXSectionHeader("UU Remote Transport")
                } footer: {
                    Text("SSH, SFTP and Monitor on this server tunnel through the UU Remote session's port mapping — open the Desktop first so the tunnel is live.")
                }
            }

            Section {
                Picker("Remote Desktop", selection: $remoteDesktopProtocol) {
                    Text("None").tag(RDMachine.RemoteDesktopProtocolType.none)
                    Text("VNC").tag(RDMachine.RemoteDesktopProtocolType.vnc)
                    Text("UU Remote").tag(RDMachine.RemoteDesktopProtocolType.uuRemote)
                }
            } header: {
                RXSectionHeader("Remote Desktop")
            }

            if remoteDesktopProtocol == .vnc {
                Section {
                    TextField("VNC Port", text: $vncPort)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numberPad)
                    SecureField("VNC Password (empty = identity password)", text: $vncPassword)
                    TextField("Mac User Name (empty = identity user)", text: $vncUsername)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    Toggle("Tunnel over SSH", isOn: $vncOverSSH)
                    Toggle("Shared session", isOn: $vncShared)
                } header: {
                    RXSectionHeader("VNC")
                }
            }

            if remoteDesktopProtocol == .uuRemote {
                Section {
                    if !uuAccount.desktopDevices.isEmpty {
                        Picker("UU Remote device", selection: $uuDeviceID) {
                            Text("Manual / assist").tag("")
                            ForEach(uuAccount.desktopDevices, id: \.deviceID) { device in
                                Text("\(device.alias.isEmpty ? device.deviceID : device.alias) · \(UUDeviceInfo.platformName(device.platform))")
                                    .tag(device.deviceID)
                            }
                        }
                    }
                    TextField("Device ID", text: $uuDeviceID)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    TextField("Assist connect ID (optional)", text: $uuAssistID)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    SecureField("Assist code (optional)", text: $uuAssistCode)
                    Button {
                        openUUAccount = true
                    } label: {
                        Label("UU Remote Account & Devices…", systemImage: "person.crop.circle")
                    }
                } header: {
                    RXSectionHeader("NetEase UU Remote")
                }
            }

            Section {
                Picker("Identity", selection: $associatedIdentity) {
                    Text("Automatic").tag(RDIdentity.ID?.none)
                    ForEach(identities) { item in
                        Text(item.group.isEmpty ? item.username : "\(item.username) · \(item.group)")
                            .tag(RDIdentity.ID?.some(item.id))
                    }
                }
            } header: {
                RXSectionHeader("Identity")
            } footer: {
                if let aid = associatedIdentity {
                    Text(CatusshStore.shared.identityGroup[aid].shortDescription())
                } else {
                    Text("Tries each identity that authenticates automatically.")
                }
            }

            Section {
                HStack {
                    TextField("Default", text: $group)
                        .textInputAutocapitalization(.never)
                    if !existingFolders.isEmpty {
                        Menu {
                            Button("Default") { group = "" }
                            Divider()
                            ForEach(existingFolders, id: \.self) { item in
                                Button(item) { group = item }
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityLabel("Existing Folders")
                    }
                }
            } header: {
                RXSectionHeader("Folder")
            }

            Section {
                HStack {
                    Text("Start folder")
                    TextField("/", text: $fileTransferLoginPath)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .font(.rxCode)
                }
            } header: {
                RXSectionHeader("SFTP")
            }

            if !isNew {
                Section {
                    Text(banner.isEmpty ? "None" : banner)
                        .font(.rxCode)
                        .foregroundStyle(banner.isEmpty ? Color.rxInkSecondary : Color.rxInk)
                        .textSelection(.enabled)
                } header: {
                    RXSectionHeader("Last banner")
                }
            }

            if isNew {
                Section {
                    Button {
                        createAndConnect()
                    } label: {
                        HStack {
                            Label("Add and Connect", systemImage: "bolt.horizontal")
                            Spacer()
                            if connecting { ProgressView() }
                        }
                    }
                    .disabled(!canSave || connecting)
                } footer: {
                    if let connectError {
                        Text(connectError).foregroundStyle(.rxDanger)
                    } else {
                        Text("Checks the connection and finds an identity that signs in, then saves the server and opens a terminal.")
                    }
                }
            }

            if let identity = inEditWith {
                Section {
                    Button {
                        UIBridge.requiresConfirmation(
                            message: "Delete this server?"
                        ) { confirmed in
                            if confirmed {
                                CatusshStore.shared.machineGroup.delete(identity)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Delete Server", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .rxGroupedList()
        .sheet(isPresented: $openUUAccount) {
            NavigationStack {
                UURemoteAccountView(onConnectDesktop: { machineID in
                    openUUAccount = false
                    ServerActions.openDesktop(machineID)
                })
                .navigationTitle("UU Remote")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { openUUAccount = false }
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New Server" : "Edit Server")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    completeSheet()
                } label: {
                    Text(isNew ? "Add" : "Save").bold()
                }
                .disabled(connecting)
            }
        }
    }

    /// The server as the form describes it, on top of what is saved, so
    /// fields this form does not show are kept.
    func makeMachine() -> RDMachine {
        var target = inEditWith.map { CatusshStore.shared.machineGroup[$0] }
            // A new server has never been connected to; RXFormat shows the epoch as "Never".
            ?? RDMachine(lastConnection: Date(timeIntervalSince1970: 0))
        target.remoteAddress = trimmedAddress
        target.remotePort = remotePort
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedAddress : name
        target.group = group.trimmingCharacters(in: .whitespacesAndNewlines)
        target.comment = comment
        target.associatedIdentity = associatedIdentity?.uuidString
        target.fileTransferLoginPath = fileTransferLoginPath.isEmpty ? "/" : fileTransferLoginPath
        target.transport = transport
        target.proxyJumpMachineID = transport == .proxyJump ? proxyJumpMachineID?.uuidString : nil
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
        return target
    }

    func validate() -> Bool {
        guard !trimmedAddress.isEmpty else {
            UIBridge.presentError(with: "Empty Address")
            return false
        }
        guard portIsValid else {
            UIBridge.presentError(with: "Invalid Port")
            return false
        }
        guard transport != .proxyJump || proxyJumpMachineID != nil else {
            UIBridge.presentError(with: "Choose a jump server")
            return false
        }
        return true
    }

    func completeSheet() {
        guard validate() else { return }
        CatusshStore.shared.machineGroup.insert(makeMachine())
        dismiss()
    }

    /// Connects first; when no identity authenticates, asks for one.
    func createAndConnect() {
        guard validate() else { return }
        connectError = nil
        connecting = true
        let draft = makeMachine()
        let host = trimmedAddress
        let port = remotePort
        let chosen = associatedIdentity.map { CatusshStore.shared.identityGroup[$0] }
        let candidates = CatusshStore.shared.identityGroupForAutoAuth
        DispatchQueue.global().async {
            let outcome = ServerConnectionCheck.run(
                draft,
                identity: chosen,
                candidates: candidates,
                timeout: CatusshStore.shared.timeoutNumber
            )
            onMainThread {
                connecting = false
                switch outcome {
                case let .unreachable(refusal):
                    connectError = refusal ?? "Could not reach \(host) on port \(port)."
                case let .authenticated(identity, banner):
                    var created = draft
                    created.associatedIdentity = identity.uuidString
                    created.lastBanner = banner
                    created.lastConnection = Date()
                    CatusshStore.shared.machineGroup.insert(created)
                    dismiss()
                    // The terminal waits for this sheet to go.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        TerminalManager.shared.begin(for: created.id)
                    }
                case .rejected:
                    if chosen != nil {
                        connectError = "The selected identity could not sign in to \(host)."
                    } else {
                        connectError = "No identity that authenticates automatically could sign in. Choose an identity."
                        Task { @MainActor in
                            guard let picked = await CatusshUtil.selectIdentity() else { return }
                            associatedIdentity = picked
                            createAndConnect()
                        }
                    }
                }
            }
        }
    }
}

struct EditMachineView_Previews: PreviewProvider {
    static var previews: some View {
        createPreview { AnyView(EditMachineView()) }
    }
}
