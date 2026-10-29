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

    init(requestMachine: UUID? = nil) {
        inEditWith = requestMachine
    }

    @State var initializedOnce = false

    @State var remoteAddress = ""
    @State var remotePort = ""
    @State var name = ""
    @State var group = ""
    @State var comment = ""
    @State var associatedIdentity: UUID? = nil
    @State var transport: RDMachine.Transport = .direct
    @State var serviceTokenID = ""
    @State var serviceTokenSecret = ""

    // Remote Desktop
    @State var remoteDesktopProtocol: RDMachine.RemoteDesktopProtocolType = .none
    @State var vncPort = "5900"
    @State var vncPassword = ""
    @State var vncOverSSH = false
    @State var vncShared = true
    @State var uuDeviceID = ""
    @State var uuAssistID = ""
    @State var uuAssistCode = ""
    @State var openUUAccount = false
    @ObservedObject var uuAccount = UURemoteAccountStore.shared

    // Extra
    @State var fileTransferLoginPath: String = "/"

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
        .onAppear {
            if initializedOnce { return }
            initializedOnce = true
            // Writing the fields synchronously in onAppear races the
            // sheet's own first update: on iOS 15 the values could be
            // swallowed and the form stayed empty. One runloop hop lets
            // the current update cycle finish before the state changes.
            DispatchQueue.main.async {
                if let edit = inEditWith {
                    let read = CatusshStore.shared.machineGroup[edit]
                    remoteAddress = read.remoteAddress
                    remotePort = read.remotePort
                    name = read.name
                    group = read.group
                    comment = read.comment
                    fileTransferLoginPath = read.fileTransferLoginPath
                    transport = read.transport
                    serviceTokenID = read.cloudflareServiceTokenID
                    serviceTokenSecret = read.cloudflareServiceTokenSecret
                    remoteDesktopProtocol = read.remoteDesktopProtocol
                    vncPort = read.vncPort
                    vncPassword = read.vncPassword
                    vncOverSSH = read.vncOverSSH
                    vncShared = read.vncShared
                    uuDeviceID = read.uuDeviceID
                    uuAssistID = read.uuAssistID
                    uuAssistCode = read.uuAssistCode
                    if let aid = read.associatedIdentity {
                        associatedIdentity = UUID(uuidString: aid)
                    }
                }
                if comment.isEmpty {
                    comment = "Created at: " + Date().formatted()
                }
                if remotePort.isEmpty {
                    remotePort = "22"
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
        guard !name.isEmpty else {
            UIBridge.presentError(with: "Empty Name")
            return
        }
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

        var newMachine = RDMachine(
            id: id,
            remoteAddress: remoteAddress,
            remotePort: remotePort,
            name: name,
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
