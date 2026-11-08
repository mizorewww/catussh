//
//  IdentitiesView.swift
//  catussh (macOS)
//
//  Identities grouped by group, with the editor beside the list.
//

import CatusshModule
import SwiftUI

struct IdentitiesView: View {
    @EnvironmentObject var store: CatusshStore

    @State private var searchText = ""
    @State private var selection: RDIdentity.ID?
    @State private var creating = false

    var filtered: [RDIdentity] {
        let all = store.identityGroup.identities
        guard !searchText.isEmpty else { return all }
        let key = searchText.lowercased()
        return all.filter {
            $0.username.lowercased().contains(key)
                || $0.group.lowercased().contains(key)
                || $0.comment.lowercased().contains(key)
        }
    }

    var groups: [(name: String, identities: [RDIdentity])] {
        let identities = filtered
        let names = Set(identities.map(\.group)).sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.map { name in
            (name, identities.filter { $0.group == name }.sorted { $0.username < $1.username })
        }
    }

    var body: some View {
        PageScaffold(
            search: $searchText,
            searchPrompt: "Search identities",
            primary: ToolbarAction("New Identity", systemImage: "plus", primary: true) { creating = true }
        ) {
        } trailing: {
        } header: {
            PageTitle("Identities")
        } content: {
            if store.identityGroup.identities.isEmpty {
                EmptyStateView(
                    "No identities yet",
                    systemImage: "person",
                    message: "A username with a password or key.",
                    actionTitle: "New Identity"
                ) {
                    creating = true
                }
                .rxCard()
            } else {
                HStack(alignment: .top, spacing: RX.Space.s4) {
                    list
                        .frame(width: 240)
                    if let selection, store.identityGroup.identities.contains(where: { $0.id == selection }) {
                        IdentityDetail(identity: selection)
                            .id(selection)
                    } else {
                        EmptyStateView("Select an identity", systemImage: "person")
                        .rxCard()
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            IdentityEditorSheet { created in
                creating = false
                if let created { selection = created }
            }
            .environmentObject(CatusshStore.shared)
        }
        .onAppear {
            if selection == nil { selection = groups.first?.identities.first?.id }
        }
    }

    var list: some View {
        VStack(spacing: 0) {
            if filtered.isEmpty {
                EmptyStateView("No matches", systemImage: "magnifyingglass")
            }
            ForEach(groups, id: \.name) { group in
                TableGroupRow(group.name.isEmpty ? "Default" : group.name)
                    .transition(.opacity)
                ForEach(Array(group.identities.enumerated()), id: \.element.id) { index, identity in
                    IdentityRow(identity: identity, selected: selection == identity.id)
                        .onTapGesture { selection = identity.id }
                        .rxRise(index)
                        .transition(.opacity)
                }
            }
        }
        .animation(.rxMove, value: groups.flatMap { $0.identities.map(\.id) })
        .rxCard(padding: RX.Space.s2)
    }
}

private struct IdentityRow: View {
    let identity: RDIdentity
    let selected: Bool
    @EnvironmentObject var store: CatusshStore
    @State private var hovered = false

    var usage: Int {
        store.machineGroup.machines.filter { $0.associatedIdentity == identity.id.uuidString }.count
    }

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(identity.username.isEmpty ? "No username" : identity.username)
                    .font(.rxBody)
                    .foregroundStyle(identity.username.isEmpty ? Color.rxInkSecondary : Color.rxInk)
                    .lineLimit(1)
                Text(identity.authDescription)
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
            }
            Spacer()
            Text("\(usage) server\(usage == 1 ? "" : "s")")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.tableRowHeight)
        .rxRowBackground(selected: selected, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Duplicate") { IdentityActions.duplicate(identity.id) }
            Button("Copy Public Key") { UIBridge.sendPasteboard(str: identity.publicKey) }
                .disabled(identity.publicKey.isEmpty)
            Divider()
            Button("Delete…", role: .destructive) { IdentityActions.delete(identity.id) }
        }
    }
}

enum IdentityActions {
    static func duplicate(_ id: RDIdentity.ID) {
        var copy = CatusshStore.shared.identityGroup[id]
        guard !copy.username.isEmpty else { return }
        copy.id = UUID()
        copy.comment = copy.comment.isEmpty ? "Copy" : copy.comment + " (copy)"
        CatusshStore.shared.identityGroup.insert(copy)
    }

    static func delete(_ id: RDIdentity.ID) {
        let store = CatusshStore.shared
        let identity = store.identityGroup[id]
        let users = store.machineGroup.machines.filter { $0.associatedIdentity == id.uuidString }.count
        UIBridge.requiresConfirmation(
            message: "Delete identity \(identity.username)?",
            informative: users > 0
                ? "\(users) server\(users == 1 ? "" : "s") use it and will try automatic identities instead."
                : "Its password and keys are removed from catussh.",
            confirmTitle: "Delete",
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            store.identityGroup.delete(id)
        }
    }
}

/// The editor beside the list.
private struct IdentityDetail: View {
    let identity: RDIdentity.ID
    @EnvironmentObject var store: CatusshStore
    @State private var draft = IdentityDraft()
    @State private var loaded = false

    var original: RDIdentity { store.identityGroup[identity] }

    var usedBy: [String] {
        store.machineGroup.machines
            .filter { $0.associatedIdentity == identity.uuidString }
            .map(\.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                // The username is the first field below; the header says
                // where the identity is used.
                HelpText(usageLine.isEmpty ? "Not used by any server" : usageLine)
                Spacer()
                Menu {
                    Button("Duplicate") { IdentityActions.duplicate(identity) }
                    Divider()
                    Button("Delete…", role: .destructive) { IdentityActions.delete(identity) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.rx(.plain, iconOnly: true))
                .fixedSize()
            }
            IdentityForm(draft: $draft)
                .padding(.top, RX.Space.s5)
            HStack(spacing: RX.Space.s2) {
                Spacer()
                Button("Revert") { draft = IdentityDraft(original) }
                    .buttonStyle(.rx)
                    .disabled(!draft.differs(from: original))
                Button("Save") {
                    store.identityGroup.insert(draft.apply(to: original))
                }
                .buttonStyle(.rxPrimary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!draft.differs(from: original) || !draft.isValid)
            }
            .padding(.top, RX.Space.s4)
        }
        .rxCard()
        .frame(maxWidth: .infinity)
        .onAppear {
            draft = IdentityDraft(original)
        }
        .onDisappear {
            // Keep edits when another identity is selected.
            let stillExists = store.identityGroup.identities.contains { $0.id == identity }
            if stillExists, draft.differs(from: original), draft.isValid {
                store.identityGroup.insert(draft.apply(to: original))
            }
        }
    }

    var usageLine: String {
        let names = usedBy
        guard !names.isEmpty else { return "" }
        let shown = names.prefix(4).joined(separator: ", ")
        let more = names.count > 4 ? " and \(names.count - 4) more" : ""
        return "Used by \(shown)\(more)"
    }
}

/// Username, Group, Key pair / Password, keys, Password, Comment, Authenticate automatically.
struct IdentityForm: View {
    @Binding var draft: IdentityDraft
    @EnvironmentObject var store: CatusshStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: RX.Space.s4) {
                RXField("Username") {
                    TextField("root", text: $draft.username)
                        .textFieldStyle(.rx)
                        .disableAutocorrection(true)
                }
                RXField("Group") {
                    TextField("Default", text: $draft.group)
                        .textFieldStyle(.rx)
                }
            }
            RXField("Authentication") {
                RXSegmented(selection: $draft.method, options: [
                    .init(.keyPair, "Key pair"),
                    .init(.password, "Password"),
                ], caps: false, fullWidth: true)
            }
            if draft.method == .keyPair {
                RXField("Private key") {
                    KeyField(
                        text: $draft.privateKey,
                        masked: true,
                        placeholder: "No private key loaded",
                        loadTitle: "Load…",
                        matches: RDIdentity.looksLikePrivateKey
                    )
                }
                RXField("Public key", help: "Optional") {
                    KeyField(
                        text: $draft.publicKey,
                        masked: false,
                        placeholder: "No public key loaded",
                        loadTitle: "Load…",
                        matches: RDIdentity.looksLikePublicKey
                    )
                }
                RXField("Passphrase") {
                    SecureField("None", text: $draft.passphrase)
                        .textFieldStyle(.rx)
                }
            } else {
                RXField("Password") {
                    SecureField("Required", text: $draft.password)
                        .textFieldStyle(.rx)
                }
            }
            RXField("Comment") {
                TextField("Optional", text: $draft.comment)
                    .textFieldStyle(.rx)
            }
            Hairline()
            SwitchRow(
                "Authenticate automatically",
                description: "Required for Quick Connect.",
                isOn: $draft.automatic
            )
        }
    }
}

/// A key shown in `code`, masked when private, with Load, Copy and Clear.
private struct KeyField: View {
    @Binding var text: String
    let masked: Bool
    let placeholder: String
    let loadTitle: String
    let matches: (String) -> Bool

    var display: String {
        guard !text.isEmpty else { return "" }
        let lines = text.split(separator: "\n").map(String.init)
        if masked {
            let header = lines.first ?? ""
            let bytes = text.utf8.count
            return "\(header)  •••••••• \(bytes) bytes"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            RXValueField(display, placeholder: placeholder, monospaced: true)
            if !text.isEmpty {
                if !masked {
                    RXIconButton("Copy", systemImage: "doc.on.doc") {
                        UIBridge.sendPasteboard(str: text)
                    }
                }
                RXIconButton("Remove", systemImage: "minus.circle") { text = "" }
            }
            Button(loadTitle) { load() }
                .buttonStyle(.rx)
                .fixedSize()
        }
    }

    func load() {
        UIBridge.openPanel(
            message: nil,
            prompt: nil,
            directory: URL(fileURLWithPath: "\(NSHomeDirectory())/.ssh/"),
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: false,
            canCreateDirectories: false,
            showsHiddenFiles: true
        ) { urls in
            guard let url = urls.first else { return }
            guard let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) else {
                UIBridge.presentError(with: "The file could not be read as text.")
                return
            }
            if matches(string) {
                text = string
            } else {
                UIBridge.requiresConfirmation(
                    message: "This file does not look like a \(masked ? "private" : "public") key",
                    informative: "Load it anyway?",
                    confirmTitle: "Load"
                ) { confirmed in
                    if confirmed { text = string }
                }
            }
        }
    }
}

/// New Identity as a sheet (from Identities and the identity picker). Existing
/// identities are edited in place on the Identities page.
struct IdentityEditorSheet: View {
    let onComplete: (RDIdentity.ID?) -> Void

    @EnvironmentObject var store: CatusshStore
    @State private var draft = IdentityDraft()

    var body: some View {
        SheetScaffold("New Identity") {
            IdentityForm(draft: $draft)
        } footer: {
            Button("Cancel") { onComplete(nil) }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Create") {
                var base = RDIdentity(
                    username: "",
                    password: "",
                    privateKey: "",
                    publicKey: "",
                    lastRecentUsed: .init(timeIntervalSince1970: 0),
                    comment: "",
                    group: "",
                    authenticAutomatically: true,
                    attachment: [:]
                )
                base = draft.apply(to: base)
                store.identityGroup.insert(base)
                onComplete(base.id)
            }
            .buttonStyle(.rxPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!draft.isValid)
        }
        .frame(width: 520)
    }
}
