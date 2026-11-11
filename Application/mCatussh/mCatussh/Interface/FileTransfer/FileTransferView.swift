//
//  FileTransferView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/18.
//

import CatusshModule
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileTransferView: View {
    @ObservedObject var context: FileTransferContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.inServerWorkspace) private var inServerWorkspace

    @State var openFilePicker: Bool = false
    @State var searchKey: String = ""
    /// The editor, when it is shown over Files.
    @State private var dropTargeted = false
    /// The folder in the order the list shows it: folders first, then by
    /// name. Sorted when the folder changes, not on every redraw.
    @State private var sorted: [FileTransferContext.RemoteFile] = []

    var fileList: [FileTransferContext.RemoteFile] {
        if searchKey.isEmpty {
            return sorted
        }
        let key = searchKey.lowercased()
        return sorted.filter { $0.name.lowercased().contains(key) }
    }

    var busy: Bool { context.processConnection || context.isProgressRunning }

    var body: some View {
        Group {
            if context.destroyedSession {
                EmptyStateView("Connection closed", systemImage: "bolt.horizontal")
            } else {
                VStack(spacing: RX.Space.s3) {
                    mainView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomToolbar
                        .disabled(context.processConnection)
                        .disabled(context.isProgressRunning)
                    hintView
                }
            }
        }
        .padding(.horizontal, RX.Space.s4)
        .padding(.bottom, RX.Space.s3)
        .background(RXBackdrop().ignoresSafeArea())
        .animation(.interactiveSpring(), value: context.currentFileList)
        .animation(.interactiveSpring(), value: context.currentHint)
        .animation(.interactiveSpring(), value: context.currentProcessingFile)
        .animation(.interactiveSpring(), value: context.processConnection)
        .navigationTitle(context.machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(context.$currentFileList) { sorted = FileTransferContext.sortedForDisplay($0) }
        // iPad: files dragged in from Files or another app are uploaded here.
        .onDrop(of: [.item], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                    .strokeBorder(Color.rxAccent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.rxAccentFill.clipShape(RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)))
                    .overlay(
                        Label("Drop to upload to \(context.currentDir)", systemImage: "arrow.up.doc")
                            .font(.headline)
                            .foregroundStyle(.rxAccent)
                    )
                    .padding(RX.Space.s4)
                    .allowsHitTesting(false)
            }
        }
        .background { keyboardShortcuts }
    }

    /// iPad hardware keyboard: the Mac's Files shortcuts.
    private var keyboardShortcuts: some View {
        Group {
            Button("Enclosing Folder") { goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(context.currentUrl.pathComponents.count <= 1 || busy || !context.connected)
            Button("Go to Folder") { goToFolder() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(busy || !context.connected)
            Button("Reload") { context.loadCurrentFileList() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(busy || !context.connected)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    var mainView: some View {
        Group {
            if context.isProgressRunning || context.processConnection {
                progressView
            } else if !context.connected {
                EmptyStateView(
                    "Connection closed",
                    systemImage: "bolt.horizontal",
                    message: context.connectionPhase == .closed ? "" : context.currentHint,
                    actionTitle: "Reconnect"
                ) {
                    context.processBootstrap()
                }
                .rxCard()
            } else {
                fileListView
            }
        }
    }

    var hintView: some View {
        Group {
            if !context.currentHint.isEmpty {
                HelpText(context.currentHint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var progressView: some View {
        let total = context.totalProgress
        let current = context.currentProgress
        let fraction: Double? = total.totalUnitCount > 0
            ? total.fractionCompleted
            : (current.totalUnitCount > 0 ? current.fractionCompleted : nil)
        let name = context.currentProcessingFile.isEmpty
            ? (context.currentHint.isEmpty ? "Working…" : context.currentHint)
            : URL(fileURLWithPath: context.currentProcessingFile).lastPathComponent
        return VStack(alignment: .leading, spacing: RX.Space.s2) {
            CardHead("Transfer")
            ProgressRowView(
                title: name,
                detail: context.currentSpeed > 0 ? RXFormat.rateString(Double(context.currentSpeed)) : "",
                fraction: fraction,
                cancel: context.currentProgressCancelable && context.continueCurrentProgress
                    ? { context.continueCurrentProgress = false }
                    : nil
            )
        }
        .rxCard()
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, RX.Space.s3)
    }

    var fileListView: some View {
        Group {
            if context.currentFileList.isEmpty {
                EmptyStateView("Empty folder", systemImage: "folder")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: RX.Space.s2) {
                        CapsLabel("\(fileList.count) item\(fileList.count == 1 ? "" : "s")")
                            .padding(.leading, RX.Space.s2)
                        RXDividedStack {
                            ForEach(fileList) { file in
                                RemoteFileElement(file: file, context: context) { path in
                                    edit(path: path)
                                }
                            }
                        }
                        .rxCard(padding: RX.Space.s2)
                    }
                    .padding(.top, RX.Space.s3)
                }
                .searchable(text: $searchKey)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var bottomToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                if !context.connected {
                    makeFloatingButton("arrow.counterclockwise") {
                        context.processBootstrap()
                    }
                }
                makeFloatingButton("xmark") {
                    if context.connected {
                        context.processShutdown()
                    } else {
                        // On a server's page, the page stays for its other tools.
                        FileTransferSessionActions.close(context) { if !inServerWorkspace { dismiss() } }
                    }
                }
                // stays available while a connection attempt hangs
                .environment(\.isEnabled, true)
                Divider().frame(height: 20)
                makeFloatingButton("doc.viewfinder") {
                    UIBridge.openFileContainer()
                }
                makeFloatingButton("folder.badge.plus") {
                    UIBridge.askForInputText(
                        title: "New Folder",
                        message: "",
                        placeholder: "Folder Name",
                        payload: "",
                        canCancel: true
                    ) { name in
                        guard name.isValidAsFilename else {
                            UIBridge.presentError(with: "Invalid Filename")
                            return
                        }
                        context.createFolder(with: name)
                    }
                }
                .disabled(!context.connected)
                makeFloatingButton("arrow.up.doc") {
                    openFilePicker = true
                }
                .sheet(isPresented: $openFilePicker, onDismiss: nil) {
                    FilePickerUIRepresentable(types: [.item], allowMultiple: true) { urls in
                        debugPrint(urls)
                        context.upload(urls: urls)
                    }
                }
                .disabled(!context.connected)
                makeFloatingButton("arrow.clockwise") {
                    context.loadCurrentFileList()
                }
                .disabled(!context.connected)
                makeFloatingButton("square.and.pencil") {
                    show(EditorCenter.shared.workspace(for: context))
                }
                .accessibilityLabel("Open Editor")
                Divider().frame(height: 20)
                makeFloatingButton("arrow.up") {
                    goUp()
                }
                .accessibilityLabel("Enclosing Folder")
                .disabled(!context.connected || context.currentUrl.pathComponents.count <= 1)
                makeFloatingButton("arrow.right") {
                    goToFolder()
                }
                .accessibilityLabel("Go to Folder")
                .disabled(!context.connected)
                pathItems
                    .disabled(!context.connected)
            }
        }
        .frame(maxWidth: .infinity)
    }

    var pathItems: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< context.currentUrl.pathComponents.count, id: \.self) { idx in
                Button {
                    rollToPath(with: idx)
                } label: {
                    Text(context.currentUrl.pathComponents[idx])
                        .font(.system(size: 13, weight: idx == context.currentUrl.pathComponents.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == context.currentUrl.pathComponents.count - 1 ? Color.rxInk : Color.rxInkSecondary)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                if idx != context.currentUrl.pathComponents.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.rxInkTertiary)
                }
            }
        }
    }

    func goUp() {
        context.navigate(path: context.currentUrl.deletingLastPathComponent().path)
    }

    func goToFolder() {
        UIBridge.askForInputText(
            title: "Go to Folder",
            message: "",
            placeholder: "/var/log",
            payload: context.currentDir,
            canCancel: true
        ) { path in
            guard !path.isEmpty, path.hasPrefix("/") else {
                UIBridge.presentError(with: "Use an absolute path starting with /.")
                return
            }
            context.navigate(path: path)
        }
    }

    /// Opens the file in the server's editor, over Files.
    func edit(path: String) {
        let workspace = EditorCenter.shared.workspace(for: context)
        workspace.open(path: path)
        show(workspace)
    }

    /// The server's page switches to its editor.
    func show(_ workspace: EditorWorkspace) {
        SessionNavigation.shared.reveal(.server(workspace.context.machine.id), tool: .editor)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard context.connected, !busy, !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let urls = DroppedURLs()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Upload-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for provider in providers {
            group.enter()
            // The file given is removed when the handler returns: it is
            // copied out first.
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                let copy = staging.appendingPathComponent(url.lastPathComponent)
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { urls.append(copy) }
            }
        }
        group.notify(queue: .main) {
            if !urls.values.isEmpty { context.upload(urls: urls.values) }
        }
        return true
    }

    func rollToPath(with index: Int) {
        var url = context.currentUrl
        let cnt = index + 1
        while url.pathComponents.count > cnt, !url.pathComponents.isEmpty {
            url.deleteLastPathComponent()
        }
        debugPrint(url.path)
        context.currentDir = url.path
        context.loadCurrentFileList()
    }

    func makeFloatingButton(_ image: String, block: @escaping () -> Void) -> some View {
        Button {
            block()
        } label: {
            Image(systemName: image)
                .font(.system(size: 15))
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.rx(iconOnly: false))
    }

    struct RemoteFileElement: View {
        let file: FileTransferContext.RemoteFile
        @ObservedObject var context: FileTransferContext
        let edit: (String) -> Void

        private var tooLargeToEdit: Bool {
            (file.fstat.size?.int64Value ?? 0) > FileTransferContext.editableSizeLimit
        }

        var body: some View {
            Button {
                open()
            } label: {
                content
            }
            .buttonStyle(.plain)
            .contextMenu { actions }
        }

        /// A folder opens; a text file opens in the editor; anything else
        /// shows its actions.
        private func open() {
            let path = context.currentUrl.appendingPathComponent(file.name).path
            if file.fstat.isDirectory {
                context.navigate(path: path)
            } else if FileTransferContext.isEditable(file) {
                edit(path)
            } else {
                download()
            }
        }

        private func download() {
            let remoteUrl = context.currentUrl.appendingPathComponent(file.name)
            let documentDir = FileManager
                .default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
            context.download(from: remoteUrl, toDir: documentDir)
        }

        @ViewBuilder private var actions: some View {
            if !file.fstat.isDirectory {
                Section {
                    Button {
                        edit(context.currentUrl.appendingPathComponent(file.name).path)
                    } label: {
                        Label(tooLargeToEdit ? "Too Large to Edit" : "Edit", systemImage: "square.and.pencil")
                    }
                    .disabled(tooLargeToEdit)
                }
            }
            if file.fstat.isDirectory {
                Section {
                    Button {
                        let path = context.currentUrl.appendingPathComponent(file.name).path
                        context.navigate(path: path)
                    } label: {
                        Label("Open", systemImage: "arrow.right")
                    }
                }
            }
            Section {
                Button {
                    UIBridge.sendPasteboard(str: file.name)
                } label: {
                    Label("Copy Name", systemImage: "doc.on.doc")
                }
                Button {
                    let path = context.currentUrl.appendingPathComponent(file.name).path
                    UIBridge.sendPasteboard(str: path)
                } label: {
                    Label("Copy Path", systemImage: "link")
                }
            }
            Section {
                Button {
                    UIBridge.askForInputText(
                        title: "Rename",
                        message: "",
                        placeholder: "New File Name",
                        payload: file.name,
                        canCancel: true
                    ) { newValue in
                        guard newValue.isValidAsFilename else {
                            UIBridge.presentError(with: "Invalid Filename")
                            return
                        }
                        let base = context.currentUrl
                        context.rename(
                            from: base.appendingPathComponent(file.name),
                            to: base.appendingPathComponent(newValue)
                        )
                    }
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            Section {
                Button {
                    download()
                } label: {
                    Label("Download", systemImage: "arrow.down")
                }
            }
            Section {
                Button(role: .destructive) {
                    let item = context.currentUrl.appendingPathComponent(file.name)
                    UIBridge.requiresConfirmation(
                        message: "Delete \(file.name)?",
                        informative: file.fstat.isDirectory
                            ? "The folder and everything in it is deleted from the server. This cannot be undone."
                            : "The file is deleted from the server. This cannot be undone.",
                        confirmTitle: "Delete"
                    ) { y in
                        if y { context.delete(item: item) }
                    }
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
            }
        }

        var content: some View {
            HStack(spacing: RX.Space.s3) {
                Image(systemName: sfAvatar)
                    .foregroundStyle(file.fstat.isDirectory ? Color.rxAccent : Color.rxInkSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.rxInkTertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Actions for \(file.name)")
            }
            .padding(.horizontal, RX.Space.s2)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }

        var sfAvatar: String {
            if file.fstat.isDirectory {
                return "folder"
            }
            if file.fstat.isLink {
                return "link"
            }
            return "doc"
        }

        var size: String {
            RXFormat.bytesString(Double(truncating: file.fstat.size ?? 0))
        }

        /// Size (for a file), modified, permissions and owner, as the Mac's columns.
        var detail: String {
            var parts: [String] = []
            if !file.fstat.isDirectory { parts.append(size) }
            if let modified = file.fstat.modificationDate {
                parts.append(Self.dateFormatter.string(from: modified))
            }
            parts.append(file.fstat.permissionDescription)
            parts.append(file.fstat.ownerUID == 0 ? "root" : String(file.fstat.ownerUID))
            return parts.joined(separator: " · ")
        }

        @MainActor static let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true
            return formatter
        }()
    }
}

/// What the drop providers fill: appended on their completion queues under
/// the lock, read once the group has drained.
private final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var values: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

enum FileTransferSessionActions {
    /// Closes a server's SFTP session, and with it the editor that works
    /// over it, asking first when a transfer runs or a file is unsaved.
    @MainActor
    static func close(_ context: FileTransferContext, then: @escaping () -> Void = {}) {
        let unsaved = EditorCenter.shared.workspaces.first { $0.id == context.id }?.hasUnsavedChanges == true
        let end = {
            FileTransferManager.shared.end(for: context.id)
            then()
        }
        if context.isProgressRunning || unsaved {
            UIBridge.requiresConfirmation(
                message: "Close the file transfer on \(context.machine.name)?",
                informative: unsaved
                    ? "Files open in the editor have changes that are not saved. They are lost if you close."
                    : "A transfer is still running and will be interrupted.",
                confirmTitle: unsaved ? "Discard Changes" : "Close",
                always: unsaved
            ) { confirmed in
                if confirmed { MainActor.assumeIsolated { end() } }
            }
        } else {
            end()
        }
    }
}

/// Bridges CatusshModule's shared file-transfer core to UIKit UI.
final class IOSFileTransferUIHandler: FileTransferUIHandler {
    func presentError(_ message: String) {
        UIBridge.presentError(with: message)
    }

    func requiresConfirmation(_ message: String, completion: @escaping (Bool) -> Void) {
        UIBridge.requiresConfirmation(message: message, confirmation: completion)
    }

    func autoOpenInterface(_ context: FileTransferContext) {
        MainActor.assumeIsolated {
            SessionNavigation.shared.reveal(.server(context.machine.id), tool: .files)
        }
    }

    func downloadCompleted() {
        UIBridge.presentSuccess(with: "Download Completed", subtitle: "Saved to Files")
    }
}
