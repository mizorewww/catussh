//
//  IdentityView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//

import CatusshModule
import SwiftUI

struct IdentityView: View {
    @EnvironmentObject var store: CatusshStore
    @State private var searchKey = ""
    @State private var openCreate = false

    var filtered: [RDIdentity] {
        let all = store.identityGroup.identities
        guard !searchKey.isEmpty else { return all }
        let key = searchKey.lowercased()
        return all.filter {
            $0.username.lowercased().contains(key)
                || $0.comment.lowercased().contains(key)
                || $0.group.lowercased().contains(key)
        }
    }

    var groups: [(name: String, identities: [RDIdentity])] {
        let names = Set(filtered.map(\.group)).sorted { lhs, rhs in
            if lhs.isEmpty { return false }
            if rhs.isEmpty { return true }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.map { name in (name, filtered.filter { $0.group == name }.sorted { $0.username < $1.username }) }
    }

    var body: some View {
        Group {
            if store.identityGroup.identities.isEmpty {
                EmptyStateView(
                    "No identities yet",
                    systemImage: "person",
                    message: "A username with a password or key.",
                    actionTitle: "New Identity"
                ) {
                    openCreate = true
                }
                .frame(maxHeight: .infinity)
                .background(RXBackdrop().ignoresSafeArea())
            } else {
                List {
                    ForEach(groups, id: \.name) { group in
                        Section {
                            ForEach(group.identities) { identity in
                                NavigationLink {
                                    EditIdentityView(requestIdentity: identity.id)
                                } label: {
                                    IdentityRow(identity: identity)
                                }
                                .rxListRow()
                                .swipeActions {
                                    Button(role: .destructive) {
                                        IdentityActions.delete(identity.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        IdentityActions.duplicate(identity.id)
                                    } label: {
                                        Label("Duplicate", systemImage: "plus.square.on.square")
                                    }
                                }
                                .contextMenu {
                                    IdentityMenuItems(identity: identity)
                                }
                            }
                        } header: {
                            RXSectionHeader(group.name.isEmpty ? "Default" : group.name)
                        }
                    }
                }
                .rxGroupedList()
                .searchable(text: $searchKey, prompt: "Search identities")
            }
        }
        .navigationTitle("Identities")
        .toolbar {
            ToolbarItem {
                Button {
                    openCreate = true
                } label: {
                    Label("New Identity", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $openCreate) {
            NavigationStack { EditIdentityView() }
        }
    }
}

/// Deploy Public Key, Copy Public Key, Duplicate; Delete.
private struct IdentityMenuItems: View {
    let identity: RDIdentity

    var body: some View {
        let publicKey = identity.publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !publicKey.isEmpty {
            Section {
                Button {
                    IdentityActions.deployPublicKey(publicKey, identityID: identity.id)
                } label: {
                    Label("Deploy Public Key (ssh-copy-id)…", systemImage: "square.and.arrow.up.on.square")
                }
                Button {
                    UIBridge.sendPasteboard(str: publicKey)
                } label: {
                    Label("Copy Public Key", systemImage: "doc.on.doc")
                }
            }
        }
        Button {
            IdentityActions.duplicate(identity.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button(role: .destructive) {
            IdentityActions.delete(identity.id)
        } label: {
            Label("Delete", systemImage: "trash")
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

    @MainActor
    static func delete(_ id: RDIdentity.ID, onDeleted: (() -> Void)? = nil) {
        let store = CatusshStore.shared
        let identity = store.identityGroup[id]
        let users = store.machineGroup.machines.filter { $0.associatedIdentity == id.uuidString }.count
        UIBridge.requiresConfirmation(
            message: "Delete identity \(identity.username)?",
            informative: users > 0
                ? "\(users) server\(users == 1 ? "" : "s") use it and will try automatic identities instead."
                : "Its password and keys are removed from catussh.",
            confirmTitle: "Delete"
        ) { confirmed in
            guard confirmed else { return }
            store.identityGroup.delete(id)
            onDeleted?()
        }
    }

    /// ssh-copy-id: pick servers, then append the public key to each one's
    /// ~/.ssh/authorized_keys. Servers that sign in automatically take the
    /// identity once every server has the key.
    @MainActor
    static func deployPublicKey(_ publicKey: String, identityID: RDIdentity.ID) {
        let pub = publicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pub.isEmpty else {
            UIBridge.presentError(with: "This identity has no public key to deploy.")
            return
        }
        Task { @MainActor in
            let machines = await CatusshUtil.selectMachine()
            guard !machines.isEmpty else { return }
            UIBridge.presentSuccess(
                with: "Deploying public key",
                subtitle: machines.count == 1 ? "To 1 server" : "To \(machines.count) servers"
            )
            DispatchQueue.global().async {
                let outcome = PublicKeyDeployment.deploy(pub, to: machines)
                onMainThread {
                    if !outcome.failed.isEmpty {
                        UIBridge.presentError(with: "Failed to deploy public key to: \(outcome.failed.joined(separator: ", ")).")
                    } else if !outcome.succeeded.isEmpty {
                        PublicKeyDeployment.adopt(identity: identityID, on: machines)
                        UIBridge.presentSuccess(
                            with: "Public key deployed",
                            subtitle: outcome.succeeded.joined(separator: ", ")
                        )
                    }
                }
            }
        }
    }
}

private struct IdentityRow: View {
    let identity: RDIdentity
    @EnvironmentObject var store: CatusshStore

    var usage: Int {
        store.machineGroup.machines.filter { $0.associatedIdentity == identity.id.uuidString }.count
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.username.isEmpty ? "No username" : identity.username)
                    .foregroundStyle(identity.username.isEmpty ? Color.rxInkSecondary : Color.rxInk)
                Text(identity.authDescription + (identity.authenticAutomatically ? " · Automatic" : ""))
                    .font(.caption)
                    .foregroundStyle(.rxInkSecondary)
            }
            Spacer()
            Text("\(usage) server\(usage == 1 ? "" : "s")")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
        }
    }
}
