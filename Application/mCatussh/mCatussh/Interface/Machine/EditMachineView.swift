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
                }
                TextField(transport == .cloudflareAccess ? "Access Hostname" : "Host Address", text: $remoteAddress)
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
        CatusshStore.shared.machineGroup.insert(newMachine)

        dismiss()
    }
}

struct EditMachineView_Previews: PreviewProvider {
    static var previews: some View {
        createPreview { AnyView(EditMachineView()) }
    }
}
