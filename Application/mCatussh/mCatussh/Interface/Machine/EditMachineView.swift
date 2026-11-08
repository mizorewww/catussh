//
//  EditMachineView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/3.
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

    init(requestMachine: UUID? = nil) {
        inEditWith = requestMachine
        if let edit = requestMachine {
            let read = CatusshStore.shared.machineGroup[edit]
            _remoteAddress = State(initialValue: read.remoteAddress)
            _remotePort = State(initialValue: read.remotePort.isEmpty ? "22" : read.remotePort)
            _name = State(initialValue: read.name)
            _group = State(initialValue: read.group)
            _comment = State(initialValue: read.comment)
            _associatedIdentity = State(initialValue: read.associatedIdentity.flatMap(UUID.init(uuidString:)))
            _transport = State(initialValue: read.transport)
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
        } else {
            _remoteAddress = State(initialValue: "")
            _remotePort = State(initialValue: "22")
            _name = State(initialValue: "")
            _group = State(initialValue: "")
            _comment = State(initialValue: "")
            _associatedIdentity = State(initialValue: nil)
            _transport = State(initialValue: .direct)
            _serviceTokenID = State(initialValue: "")
            _serviceTokenSecret = State(initialValue: "")
            _remoteDesktopProtocol = State(initialValue: .none)
            _vncPort = State(initialValue: "5900")
            _vncPassword = State(initialValue: "")
            _vncUsername = State(initialValue: "")
            _vncOverSSH = State(initialValue: false)
            _vncShared = State(initialValue: true)
            _uuDeviceID = State(initialValue: "")
            _uuAssistID = State(initialValue: "")
            _uuAssistCode = State(initialValue: "")
            _fileTransferLoginPath = State(initialValue: "/")
        }
    }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name)
                TextField("Comment", text: $comment)
            } header: {
                RXSectionHeader("Name")
            }

            Section {
                Picker("Connect through", selection: $transport) {
                    Text("Direct (TCP)").tag(RDMachine.Transport.direct)
                    Text("Cloudflare Access").tag(RDMachine.Transport.cloudflareAccess)
                    Text("NetEase UU Remote").tag(RDMachine.Transport.uuRemote)
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
                Button {
                    Task { @MainActor in
                        let identity = await CatusshUtil.selectIdentity()
                        associatedIdentity = identity
                    }
                } label: {
                    Label("Select Identity", systemImage: "arrow.right")
                        .foregroundColor(.accentColor)
                }
            } header: {
                RXSectionHeader("Identity")
            } footer: {
                if let aid = associatedIdentity {
                    Text(CatusshStore.shared.identityGroup[aid].shortDescription())
                } else {
                    Text("Automatic")
                }
            }

            Section {
                TextField("Default", text: $group)
                    .textInputAutocapitalization(.never)
            } header: {
                RXSectionHeader("Group")
            }

            Section {
                HStack {
                    Text("Start folder")
                    TextField("", text: $fileTransferLoginPath)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                }
            } header: {
                RXSectionHeader("SFTP")
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
        .navigationTitle(inEditWith == nil ? "New Server" : "Edit Server")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    completeSheet()
                } label: {
                    Text("Save").bold()
                }
            }
        }
    }

    func completeSheet() {
        guard !remoteAddress.isEmpty else {
            UIBridge.presentError(with: "Empty Address")
            return
        }
        guard !remotePort.isEmpty else {
            UIBridge.presentError(with: "Empty Port")
            return
        }
        guard let port = Int(remotePort), (0 ... 65535).contains(port) else {
            UIBridge.presentError(with: "Invalid Port")
            return
        }

        let id = inEditWith ?? UUID()
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? remoteAddress : name

        var newMachine = RDMachine(
            id: id,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            name: finalName,
            group: group,
            comment: comment,
            associatedIdentity: associatedIdentity?.uuidString
        )
        newMachine.fileTransferLoginPath = fileTransferLoginPath
        newMachine.transport = transport
        let cloudflare = transport == .cloudflareAccess
        newMachine.cloudflareServiceTokenID = cloudflare ? serviceTokenID.trimmingCharacters(in: .whitespaces) : ""
        newMachine.cloudflareServiceTokenSecret = cloudflare ? serviceTokenSecret.trimmingCharacters(in: .whitespaces) : ""
        newMachine.remoteDesktopProtocol = remoteDesktopProtocol
        newMachine.vncPort = vncPort
        newMachine.vncPassword = vncPassword
        newMachine.vncUsername = vncUsername.trimmingCharacters(in: .whitespaces)
        newMachine.vncOverSSH = vncOverSSH
        newMachine.vncShared = vncShared
        newMachine.uuDeviceID = uuDeviceID.trimmingCharacters(in: .whitespaces)
        newMachine.uuAssistID = uuAssistID.trimmingCharacters(in: .whitespaces)
        newMachine.uuAssistCode = uuAssistCode
        CatusshStore.shared.machineGroup.insert(newMachine)

        dismiss()
    }
}

struct EditMachineView_Previews: PreviewProvider {
    static var previews: some View {
        createPreview { AnyView(EditMachineView()) }
    }
}
