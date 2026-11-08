//
//  EditIdentityView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//

import CatusshModule
import SwiftUI

struct EditIdentityView: View {
    @Environment(\.dismiss) private var dismiss

    let inEditWith: UUID?

    @State var username: String
    @State var password: String
    @State var privateKey: String
    @State var publicKey: String
    @State var comment: String
    @State var group: String
    @State var autoAuth: Bool

    @State var showPassword = false

    init(requestIdentity: UUID? = nil) {
        inEditWith = requestIdentity
        if let edit = requestIdentity {
            let read = CatusshStore.shared.identityGroup[edit]
            _username = State(initialValue: read.username)
            _password = State(initialValue: read.password)
            _privateKey = State(initialValue: read.privateKey)
            _publicKey = State(initialValue: read.publicKey)
            _comment = State(initialValue: read.comment)
            _group = State(initialValue: read.group)
            _autoAuth = State(initialValue: read.authenticAutomatically)
        } else {
            _username = State(initialValue: "")
            _password = State(initialValue: "")
            _privateKey = State(initialValue: "")
            _publicKey = State(initialValue: "")
            _comment = State(initialValue: "")
            _group = State(initialValue: "")
            _autoAuth = State(initialValue: true)
        }
    }

    var body: some View {
        List {
            Section {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            } header: {
                RXSectionHeader("Username")
            }

            Section {
                if showPassword {
                    TextField("Password", text: $password)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Button {
                        showPassword = false
                    } label: {
                        Label("Hide Password", systemImage: "eye.slash")
                    }
                } else {
                    SecureField("Password", text: $password)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Button {
                        CatusshUtil.deviceOwnershipAuthenticate { success in
                            if success { showPassword = true }
                        }
                    } label: {
                        Label("Show Password", systemImage: "eye")
                    }
                }
            } header: {
                RXSectionHeader("Password")
            } footer: {
                Text("Optional. Also unlocks the private key.")
            }

            Section {
                privateKeyButtons
            } header: {
                RXSectionHeader("Private Key")
            } footer: {
                Text(privateKeyDescription)
            }

            Section {
                publicKeyButtons
            } header: {
                RXSectionHeader("Public Key")
            } footer: {
                Text(publicKeyDescription)
            }

            Section {
                Toggle(isOn: $autoAuth) {
                    Text("Authenticate automatically")
                }
            } footer: {
                Text("Required for Quick Connect.")
            }

            Section {
                TextField("Comment", text: $comment)
            } header: {
                RXSectionHeader("Comment")
            }

            Section {
                TextField("Default", text: $group)
                    .textInputAutocapitalization(.never)
            } header: {
                RXSectionHeader("Group")
            }
            if let identity = inEditWith {
                Section {
                    Button {
                        UIBridge.requiresConfirmation(
                            message: "Delete this identity?"
                        ) { confirmed in
                            if confirmed {
                                CatusshStore.shared.identityGroup.delete(identity)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Delete Identity", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .rxGroupedList()
        .navigationTitle(inEditWith == nil ? "New Identity" : "Edit Identity")
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

    var privateKeyDescription: String {
        dataDescriptionFor(privateKey)
    }

    var publicKeyDescription: String {
        dataDescriptionFor(publicKey)
    }

    var privateKeyButtons: some View {
        Group {
            FilePicker(types: [.item], allowMultiple: false) { urls in
                guard let url = urls.first else {
                    return
                }
                loadPrivateKey(url: url)
            } label: {
                Label("Import from file", systemImage: "square.and.arrow.down.fill")
            }
            Button {
                loadPrivateKey(str: UIPasteboard.general.string)
            } label: {
                Label("Import from Pasteboard", systemImage: "doc.on.clipboard.fill")
            }
            Button {
                privateKey = ""
            } label: {
                Label("Clear Key Data", systemImage: "trash.fill")
            }
            .disabled(privateKey.isEmpty)
        }
    }

    var publicKeyButtons: some View {
        Group {
            FilePicker(types: [.item], allowMultiple: false) { urls in
                guard let url = urls.first else {
                    return
                }
                loadPublicKey(url: url)
            } label: {
                Label("Import from file", systemImage: "square.and.arrow.down.fill")
            }
            Button {
                loadPublicKey(str: UIPasteboard.general.string)
            } label: {
                Label("Import from Pasteboard", systemImage: "doc.on.clipboard.fill")
            }
            Button {
                publicKey = ""
            } label: {
                Label("Clear Key Data", systemImage: "trash.fill")
            }
            .disabled(publicKey.isEmpty)
        }
    }

    func loadPrivateKey(url: URL) {
        guard let data = try? String(contentsOfFile: url.path) else {
            UIBridge.presentError(with: "Unable to read")
            return
        }
        loadPrivateKey(str: data)
    }

    func loadPublicKey(url: URL) {
        guard let data = try? String(contentsOfFile: url.path) else {
            UIBridge.presentError(with: "Unable to read")
            return
        }
        loadPublicKey(str: data)
    }

    func loadPrivateKey(str: String?) {
        guard let str = str else {
            UIBridge.presentError(with: "Unable to read")
            return
        }
        if RDIdentity.looksLikePrivateKey(str) {
            privateKey = str
        } else {
            UIBridge.requiresConfirmation(
                message: "File does not look like a private key, still load the key?"
            ) { confirmed in
                if confirmed { privateKey = str }
            }
        }
    }

    func loadPublicKey(str: String?) {
        guard let str = str else {
            UIBridge.presentError(with: "Unable to read")
            return
        }
        if RDIdentity.looksLikePublicKey(str) {
            publicKey = str
        } else {
            UIBridge.requiresConfirmation(
                message: "File does not look like a public key, still load the key?"
            ) { confirmed in
                if confirmed { publicKey = str }
            }
        }
    }

    func dataDescriptionFor(_ str: String) -> String {
        if str.count > 0,
           let data = str.data(using: .utf8),
           data.count > 0
        {
            return "<\(data.count)> bytes"
        }
        return "No Data (Optional)"
    }

    func completeSheet() {
        guard !username.isEmpty else {
            UIBridge.presentError(with: "Empty Username")
            return
        }

        let id = inEditWith ?? UUID()

        let newIdentity = RDIdentity(
            id: id,
            username: username,
            password: password,
            privateKey: privateKey,
            publicKey: publicKey,
            lastRecentUsed: Date(timeIntervalSince1970: 0),
            comment: comment,
            group: group,
            authenticAutomatically: autoAuth,
            attachment: [:]
        )

        CatusshStore.shared.identityGroup.insert(newIdentity)

        dismiss()
    }
}

struct EditIdentityView_Previews: PreviewProvider {
    static var previews: some View {
        createPreview {
            AnyView(EditIdentityView())
        }
    }
}
