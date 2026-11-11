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
        SheetPresenter.present { dismiss in
            FolderNameSheet(
                title: "New Folder",
                lead: "Name the folder.",
                confirmTitle: "Create",
                initialText: store.availableFolderName("New Folder")
            ) { name in
                dismiss()
                guard let name else { return }
                let folder = store.createFolder(named: name)
                store.moveServers(servers, toFolder: folder.name)
            }
        }
    }

    @MainActor
    static func rename(_ name: String) {
        SheetPresenter.present { dismiss in
            FolderNameSheet(
                title: "Rename Folder",
                lead: "The servers in it move with it.",
                confirmTitle: "Rename",
                initialText: name
            ) { newName in
                dismiss()
                guard let newName else { return }
                if !CatusshStore.shared.renameFolder(name, to: newName) {
                    UIBridge.presentError(with: "There is already a folder named \"\(newName)\".")
                }
            }
        }
    }

    @MainActor
    static func delete(_ name: String) {
        let plan = FolderDeletionPlan(folder: name)
        UIBridge.requiresConfirmation(
            message: plan.message,
            informative: plan.informative,
            confirmTitle: plan.confirmTitle,
            destructive: true
        ) { confirmed in
            guard confirmed else { return }
            MainActor.assumeIsolated {
                plan.perform()
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
            }, onOpenTerminal: { machineID in
                dismiss()
                ServerTool.terminal.show(machineID)
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
            RXMenuItem("Default") { store.moveServers([machine], toFolder: "") }
                .disabled(current.isEmpty)
            if !targets.isEmpty { Divider() }
            ForEach(targets) { folder in
                RXMenuItem(folder.name) { store.moveServers([machine], toFolder: folder.name) }
                    .disabled(folder.name == current)
            }
            Divider()
            RXMenuItem("New Folder…") { FolderActions.newFolder(moving: [machine]) }
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
                .accessibilityHidden(true)
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
        Text(signedIn ? (account.nickname.isEmpty ? "Signed in" : account.nickname) : "Signed out")
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
        RXMenuButton("Folder Actions", systemImage: "ellipsis", kind: .plain, size: .small, iconOnly: true) {
            menuItems
        }
    }

    @ViewBuilder private var menuItems: some View {
        if case .uuRemote = folder?.source {
            RXMenuItem("UU Remote Account…") { FolderActions.linkUURemote() }
            Divider()
        }
        RXMenuItem("Rename…") { FolderActions.rename(name) }
        // A linked folder goes with its account: deleting it signs out.
        if folder?.isLinked == true {
            RXMenuItem("Remove Folder and Sign Out…", role: .destructive) { FolderActions.delete(name) }
        } else {
            RXMenuItem("Delete Folder…", role: .destructive) { FolderActions.delete(name) }
        }
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

private struct FolderNameSheet: View {
    let title: String
    let lead: String
    let confirmTitle: String
    let initialText: String
    let onComplete: (String?) -> Void

    @State private var text = ""

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetScaffold(title, lead: lead) {
            RXField("Folder name") {
                TextField("Folder name", text: $text)
                    .textFieldStyle(.rx)
                    .onSubmit {
                        if !trimmed.isEmpty { onComplete(trimmed) }
                    }
            }
        } footer: {
            Button("Cancel") { onComplete(nil) }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(confirmTitle) { onComplete(trimmed) }
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
        }
        .frame(width: 420)
        .onAppear { text = initialText }
    }
}

