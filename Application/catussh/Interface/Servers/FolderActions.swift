//
//  FolderActions.swift
//  catussh (macOS)
//
//  Folders of servers: making, renaming and deleting them, moving servers
//  between them, and the header each one has in the Servers table. A folder
//  linked to a UU Remote account shows the account and refreshes from it.
//

import CatusshDesign
import CatusshModule
import SwiftUI

enum FolderActions {
    @MainActor
    static func newFolder(moving servers: [RDMachine.ID] = []) {
        let store = CatusshStore.shared
        UIBridge.askForInput(title: "New Folder", message: "Name the folder.", defaultValue: store.availableFolderName("New Folder")) { name in
            MainActor.assumeIsolated {
                let folder = store.createFolder(named: name)
                store.moveServers(servers, toFolder: folder.name)
            }
        }
    }

    @MainActor
    static func rename(_ name: String) {
        UIBridge.askForInput(title: "Rename Folder", message: "The servers in it move with it.", defaultValue: name) { newName in
            MainActor.assumeIsolated {
                if !CatusshStore.shared.renameFolder(name, to: newName) {
                    UIBridge.presentError(with: "There is already a folder named \"\(newName)\".")
                }
            }
        }
    }

    @MainActor
    static func delete(_ name: String) {
        let store = CatusshStore.shared
        let account = UURemoteAccountStore.shared
        // The signed-in account's folder: deleting it signs out, or the next
        // refresh would make it again.
        let unlinks = account.isLoggedIn && store.folder(named: name) == account.folder(store: store)
        let count = store.machines(inFolder: name).count
        var consequences: [String] = []
        if unlinks { consequences.append("catussh signs out of UU Remote; the devices stay on the account.") }
        if count > 0 { consequences.append("Servers you added to it by hand move to Default.") }
        UIBridge.requiresConfirmation(
            message: "Delete the folder \"\(name)\"?",
            informative: consequences.isEmpty ? nil : consequences.joined(separator: " "),
            confirmTitle: unlinks ? "Delete and Sign Out" : "Delete Folder",
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            MainActor.assumeIsolated {
                if unlinks { account.logout() }
                store.deleteFolder(name)
            }
        }
    }

    /// Signs in to UU Remote; once signed in, the account's devices fill a
    /// folder of their own.
    @MainActor
    static func linkUURemote() {
        SheetPresenter.present { dismiss in
            UURemoteAccountSheet(onConnectDesktop: { machineID in
                dismiss()
                AppRouter.shared.openDesktop(machine: machineID)
            }, close: dismiss)
        }
    }
}

/// "Move to Folder" for a server's context menu.
struct MoveToFolderMenu: View {
    let machine: RDMachine.ID
    // Not from the environment: a context menu may be built outside it.
    @ObservedObject private var store = CatusshStore.shared

    var body: some View {
        let current = store.machineGroup[machine].group
        // A linked folder is filled from its account, not by hand.
        let targets = store.folders.filter { !$0.isLinked }
        Menu {
            Button("Default") { store.moveServers([machine], toFolder: "") }
                .disabled(current.isEmpty)
            if !targets.isEmpty { Divider() }
            ForEach(targets) { folder in
                Button(folder.name) { store.moveServers([machine], toFolder: folder.name) }
                    .disabled(folder.name == current)
            }
            Divider()
            Button("New Folder…") { FolderActions.newFolder(moving: [machine]) }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
    }
}

/// A folder's row in the Servers table: name and count; for a linked folder,
/// the account and Refresh; its actions in a menu.
struct FolderHeaderRow: View {
    let name: String
    let count: Int
    @EnvironmentObject var store: CatusshStore
    @ObservedObject private var account = UURemoteAccountStore.shared
    @State private var refreshing = false
    @State private var refreshError: String?

    private var folder: RDFolder? { store.folder(named: name) }

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            Image(systemName: folder?.isLinked == true ? "link" : "folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.rxInkSecondary)
            Text(name.isEmpty ? "Default" : name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.rxInkSecondary)
            Text("\(count)")
                .font(.system(size: 11))
                .foregroundStyle(.rxInkSecondary)
            if case .uuRemote = folder?.source {
                linkedStatus
            }
            Spacer()
            if !name.isEmpty { menu }
        }
        .padding(.horizontal, RX.Space.s3)
        .padding(.top, RX.Space.s3)
        .padding(.bottom, 6)
        .contextMenu { if !name.isEmpty { menuItems } }
    }

    @ViewBuilder private var linkedStatus: some View {
        let signedIn = account.isLoggedIn && folder == account.folder(store: store)
        Text("·").foregroundStyle(.rxInkSecondary)
        Text(signedIn ? (account.nickname.isEmpty ? account.userID : account.nickname) : "Signed out")
            .font(.system(size: 11))
            .foregroundStyle(signedIn ? Color.rxInkSecondary : Color.rxWarning)
            .lineLimit(1)
        if signedIn {
            Button {
                refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.rx(.plain, size: .small))
            .disabled(refreshing)
            .help(refreshError ?? "Fetch the account's devices again")
        } else {
            Button("Sign In…") { FolderActions.linkUURemote() }
                .buttonStyle(.rx(.plain, size: .small))
        }
        if let refreshError {
            Text(refreshError)
                .font(.system(size: 11))
                .foregroundStyle(.rxDanger)
                .lineLimit(1)
        }
    }

    private var menu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.rxInkSecondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Folder actions")
    }

    @ViewBuilder private var menuItems: some View {
        if case .uuRemote = folder?.source {
            Button("UU Remote Account…") { FolderActions.linkUURemote() }
            Divider()
        }
        Button("Rename…") { FolderActions.rename(name) }
        Button("Delete Folder…", role: .destructive) { FolderActions.delete(name) }
    }

    private func refresh() {
        refreshing = true
        refreshError = nil
        Task { @MainActor in
            defer { refreshing = false }
            do {
                try await account.refreshDevices()
            } catch {
                refreshError = error.localizedDescription
            }
        }
    }
}
