//
//  FolderActions.swift
//  mCatussh
//
//  Folders of servers: making, renaming and deleting them, moving servers
//  between them, and the header each one has in the Servers list. A folder
//  linked to a UU Remote account shows the link and refreshes from it.
//

import CatusshModule
import SwiftUI

enum FolderActions {
    @MainActor
    static func newFolder(moving servers: [RDMachine.ID] = []) {
        let store = CatusshStore.shared
        UIBridge.askForInputText(
            title: "New Folder",
            message: "Name the folder.",
            placeholder: "Folder name",
            payload: store.availableFolderName("New Folder"),
            canCancel: true
        ) { text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let folder = store.createFolder(named: name)
            store.moveServers(servers, toFolder: folder.name)
        }
    }

    @MainActor
    static func rename(_ name: String) {
        UIBridge.askForInputText(
            title: "Rename Folder",
            message: "The servers in it move with it.",
            placeholder: "Folder name",
            payload: name,
            canCancel: true
        ) { text in
            let newName = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            if !CatusshStore.shared.renameFolder(name, to: newName) {
                UIBridge.presentError(with: "There is already a folder named \"\(newName)\".")
            }
        }
    }

    @MainActor
    static func delete(_ name: String) {
        let plan = FolderDeletionPlan(folder: name)
        UIBridge.requiresConfirmation(
            message: plan.message,
            informative: plan.informative,
            confirmTitle: plan.confirmTitle
        ) { confirmed in
            guard confirmed else { return }
            plan.perform()
        }
    }

    /// Fetches the linked account's devices again; they fill its folder.
    @MainActor
    static func refreshLinked() {
        Task { @MainActor in
            do {
                try await UURemoteAccountStore.shared.refreshDevices()
            } catch {
                UIBridge.presentError(with: error.localizedDescription)
            }
        }
    }
}

/// "Move to Folder" for a server's menu.
struct MoveToFolderMenu: View {
    let machine: RDMachine.ID
    // Not from the environment: a menu may be built outside it.
    @ObservedObject private var store = CatusshStore.shared

    var body: some View {
        let current = store.machineGroup[machine].group
        // A linked folder is filled from its account, not by hand.
        let targets = store.folders.filter { !$0.isLinked }
        Menu {
            Button {
                store.moveServers([machine], toFolder: "")
            } label: {
                Label("Default", systemImage: current.isEmpty ? "checkmark" : "tray")
            }
            .disabled(current.isEmpty)
            if !targets.isEmpty {
                Section {
                    ForEach(targets) { folder in
                        Button {
                            store.moveServers([machine], toFolder: folder.name)
                        } label: {
                            Label(folder.name, systemImage: folder.name == current ? "checkmark" : "folder")
                        }
                        .disabled(folder.name == current)
                    }
                }
            }
            Section {
                Button {
                    FolderActions.newFolder(moving: [machine])
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
    }
}

/// A folder's section header in the Servers list: name and count, and for
/// a folder other than Default, its actions in a menu.
struct FolderSectionHeader: View {
    let name: String
    let count: Int
    @EnvironmentObject var store: CatusshStore
    @ObservedObject private var account = UURemoteAccountStore.shared

    private var folder: RDFolder? { store.folder(named: name) }

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            if folder?.isLinked == true {
                Image(systemName: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.rxInkSecondary)
                    .accessibilityHidden(true)
            }
            RXSectionHeader(name.isEmpty ? "Default" : name)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
            if case .uuRemote = folder?.source {
                Text(signedIn ? (account.nickname.isEmpty ? "Signed in" : account.nickname) : "Signed out")
                    .font(.caption)
                    .foregroundStyle(signedIn ? Color.rxInkSecondary : Color.rxWarning)
                    .lineLimit(1)
                    .textCase(nil)
            }
            Spacer()
            if !name.isEmpty {
                Menu {
                    FolderMenuItems(name: name)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.rxInkSecondary)
                        .frame(minWidth: 28, minHeight: 28)
                }
                .accessibilityLabel("Folder Actions")
            }
        }
    }

    private var signedIn: Bool {
        account.isLoggedIn && folder == account.folder(store: store)
    }
}

/// Rename and Delete; for the signed-in account's folder, Refresh.
struct FolderMenuItems: View {
    let name: String
    @ObservedObject private var store = CatusshStore.shared
    @ObservedObject private var account = UURemoteAccountStore.shared

    var body: some View {
        let folder = store.folder(named: name)
        if case .uuRemote = folder?.source, account.isLoggedIn, folder == account.folder(store: store) {
            Button {
                FolderActions.refreshLinked()
            } label: {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
            }
        }
        Button {
            FolderActions.rename(name)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        // A linked folder goes with its account: deleting it signs out.
        Button(role: .destructive) {
            FolderActions.delete(name)
        } label: {
            Label(folder?.isLinked == true ? "Remove Folder and Sign Out…" : "Delete Folder…", systemImage: "trash")
        }
    }
}
