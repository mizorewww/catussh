//
//  EditIdentityView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//
//  Username, Group, Key pair / Password (/ SSH Agent), keys with Generate
//  Ed25519, Passphrase or Password, Comment, Authenticate automatically; an
//  existing identity can deploy its public key (ssh-copy-id).
//

import CatusshModule
import SwiftUI

struct EditIdentityView: View {
    @Environment(\.dismiss) private var dismiss

    let inEditWith: UUID?
    let original: RDIdentity

    @State var draft: IdentityDraft
    @State var showPassword = false

    /// SSH Agent signs in through the Mac's agent; it is offered only to
    /// keep an identity that already uses it, say one synced from a Mac.
    let offersSSHAgent: Bool

    init(requestIdentity: UUID? = nil) {
        inEditWith = requestIdentity
        let read = requestIdentity.map { CatusshStore.shared.identityGroup[$0] }
            ?? RDIdentity(lastRecentUsed: Date(timeIntervalSince1970: 0))
        original = read
        offersSSHAgent = read.useSSHAgent
        _draft = State(initialValue: IdentityDraft(read))
    }

    var body: some View {
        List {
            Section {
                TextField("Username", text: $draft.username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            } header: {
                RXSectionHeader("Username")
            }

            Section {
                Picker("Authentication", selection: $draft.method) {
                    Text("Key pair").tag(IdentityDraft.Method.keyPair)
                    Text("Password").tag(IdentityDraft.Method.password)
                    if offersSSHAgent {
                        Text("SSH Agent").tag(IdentityDraft.Method.sshAgent)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                if draft.method == .sshAgent {
                    Text("Signs in using the Mac's running SSH agent (SSH_AUTH_SOCK). iPhone and iPad have no SSH agent, so this identity signs in only from catussh on a Mac.")
                }
            }

            switch draft.method {
            case .keyPair:
                keyPairSections
            case .password:
                passwordSection
            case .sshAgent:
                EmptyView()
            }

            Section {
                Toggle(isOn: $draft.automatic) {
                    Text("Authenticate automatically")
                }
            } footer: {
                Text("Required for Quick Connect.")
            }

            Section {
                TextField("Optional", text: $draft.comment)
            } header: {
                RXSectionHeader("Comment")
            }

            Section {
                TextField("Default", text: $draft.group)
                    .textInputAutocapitalization(.never)
            } header: {
                RXSectionHeader("Group")
            }

            if let identity = inEditWith {
                Section {
                    if draft.method == .keyPair, !trimmedPublicKey.isEmpty {
                        Button {
                            IdentityActions.deployPublicKey(draft.publicKey, identityID: identity)
                        } label: {
                            Label("Deploy Public Key (ssh-copy-id)…", systemImage: "square.and.arrow.up.on.square")
                        }
                    }
                    Button {
                        IdentityActions.duplicate(identity)
                        dismiss()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                } footer: {
                    if draft.method == .keyPair, !trimmedPublicKey.isEmpty {
                        Text("Deploying appends the public key to ~/.ssh/authorized_keys on the servers you choose.")
                    }
                }
                Section {
                    Button {
                        IdentityActions.delete(identity) { dismiss() }
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
            if inEditWith == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    completeSheet()
                } label: {
                    Text(inEditWith == nil ? "Create" : "Save").bold()
                }
            }
        }
    }

    var trimmedPublicKey: String {
        draft.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Key pair

    @ViewBuilder var keyPairSections: some View {
        Section {
            FilePicker(types: [.item], allowMultiple: false) { urls in
                guard let url = urls.first else { return }
                loadKey(url: url, isPrivate: true)
            } label: {
                Label("Import from File", systemImage: "square.and.arrow.down.fill")
            }
            Button {
                loadKey(str: UIPasteboard.general.string, isPrivate: true)
            } label: {
                Label("Import from Pasteboard", systemImage: "doc.on.clipboard.fill")
            }
            Button {
                generateKeyPair()
            } label: {
                Label("Generate Ed25519 Key Pair", systemImage: "key.horizontal")
            }
            Button(role: .destructive) {
                draft.privateKey = ""
            } label: {
                Label("Clear Key Data", systemImage: "trash.fill")
            }
            .disabled(draft.privateKey.isEmpty)
        } header: {
            RXSectionHeader("Private Key")
        } footer: {
            Text(privateKeyDescription)
        }

        Section {
            if !trimmedPublicKey.isEmpty {
                Text(trimmedPublicKey)
                    .font(.rxCode)
                    .foregroundStyle(.rxInk)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    UIBridge.sendPasteboard(str: trimmedPublicKey)
                } label: {
                    Label("Copy Public Key", systemImage: "doc.on.doc")
                }
                ShareLink(item: trimmedPublicKey + "\n") {
                    Label("Share Public Key", systemImage: "square.and.arrow.up")
                }
            }
            FilePicker(types: [.item], allowMultiple: false) { urls in
                guard let url = urls.first else { return }
                loadKey(url: url, isPrivate: false)
            } label: {
                Label("Import from File", systemImage: "square.and.arrow.down.fill")
            }
            Button {
                loadKey(str: UIPasteboard.general.string, isPrivate: false)
            } label: {
                Label("Import from Pasteboard", systemImage: "doc.on.clipboard.fill")
            }
            Button(role: .destructive) {
                draft.publicKey = ""
            } label: {
                Label("Clear Key Data", systemImage: "trash.fill")
            }
            .disabled(draft.publicKey.isEmpty)
        } header: {
            RXSectionHeader("Public Key")
        } footer: {
            Text(trimmedPublicKey.isEmpty ? "Optional. Needed to deploy the key to servers." : (draft.keyAlgorithmLabel ?? "Public key"))
        }

        Section {
            SecureField("None", text: $draft.passphrase)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
        } header: {
            RXSectionHeader("Passphrase")
        } footer: {
            Text("Unlocks the private key, when it has one.")
        }
    }

    var privateKeyDescription: String {
        guard !draft.privateKey.isEmpty else { return "Required for a key pair." }
        let header = draft.privateKey.split(separator: "\n").first.map(String.init) ?? ""
        return "\(header) · \(draft.privateKey.utf8.count) bytes"
    }

    func generateKeyPair() {
        let replace = {
            draft.generateEd25519KeyPair()
            UIBridge.presentSuccess(with: "Generated an Ed25519 key pair")
        }
        guard draft.privateKey.isEmpty else {
            UIBridge.requiresConfirmation(
                message: "Replace the key pair?",
                informative: "Servers that only accept the current key stop accepting this identity.",
                confirmTitle: "Replace"
            ) { confirmed in
                if confirmed { replace() }
            }
            return
        }
        replace()
    }

    // MARK: - Password

    var passwordSection: some View {
        Section {
            if showPassword {
                TextField("Password", text: $draft.password)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Button {
                    showPassword = false
                } label: {
                    Label("Hide Password", systemImage: "eye.slash")
                }
            } else {
                SecureField("Password", text: $draft.password)
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
        }
    }

    // MARK: - Loading keys

    func loadKey(url: URL, isPrivate: Bool) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            UIBridge.presentError(with: "The file could not be read as text.")
            return
        }
        loadKey(str: data, isPrivate: isPrivate)
    }

    func loadKey(str: String?, isPrivate: Bool) {
        guard let str, !str.isEmpty else {
            UIBridge.presentError(with: "Unable to read")
            return
        }
        let matches = isPrivate ? RDIdentity.looksLikePrivateKey(str) : RDIdentity.looksLikePublicKey(str)
        let apply = {
            if isPrivate { draft.privateKey = str } else { draft.publicKey = str }
        }
        if matches {
            apply()
        } else {
            UIBridge.requiresConfirmation(
                message: "This does not look like a \(isPrivate ? "private" : "public") key",
                informative: "Load it anyway?",
                confirmTitle: "Load",
                destructive: false
            ) { confirmed in
                if confirmed { apply() }
            }
        }
    }

    func completeSheet() {
        guard !draft.username.trimmingCharacters(in: .whitespaces).isEmpty else {
            UIBridge.presentError(with: "Empty Username")
            return
        }
        guard draft.isValid else {
            UIBridge.presentError(with: draft.method == .keyPair ? "A key pair needs a private key" : "Empty Password")
            return
        }
        CatusshStore.shared.identityGroup.insert(draft.apply(to: original))
        dismiss()
    }
}

private extension IdentityDraft {
    /// "ed25519 public key" style line for the key in the draft.
    var keyAlgorithmLabel: String? {
        var probe = RDIdentity()
        probe.publicKey = publicKey
        probe.privateKey = privateKey
        return probe.keyAlgorithm.map { "\($0) public key" }
    }
}

struct EditIdentityView_Previews: PreviewProvider {
    static var previews: some View {
        createPreview {
            AnyView(EditIdentityView())
        }
    }
}
