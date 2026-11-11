//
//  FileTransferPage.swift
//  catussh (macOS)
//
//  SFTP inside the main window: Up, breadcrumb, Go to Folder, filter, Reload,
//  New Folder, Upload, Download. Table: name, size, modified, permissions, owner.
//  Transfer card with speed and Cancel. Drag files in to upload. Double-click a
//  file to edit it.
//

import CatusshModule
import SwiftUI
import UniformTypeIdentifiers

struct FileTransferPage: View {
    @ObservedObject var context: FileTransferContext
    @EnvironmentObject var store: CatusshStore

    @State private var filter = ""
    @State private var selection: FileTransferContext.RemoteFile?
    @State private var prompt: FilePrompt?
    @State private var dropTargeted = false

    /// The whole folder in the table's order: folders first, then by name.
    /// Sorted when the folder changes, not on every redraw: a transfer's
    /// progress redraws the page many times a second.
    @State private var sorted: [FileTransferContext.RemoteFile] = []
    /// What the table shows: `sorted`, less what the filter leaves out.
    @State private var files: [FileTransferContext.RemoteFile] = []
    /// Counts the changes of `files`, so the table needn't compare lists.
    @State private var revision = 0
    /// Counts the folder listings, so a slow sort of an old one is dropped.
    @State private var listing = 0

    nonisolated static func sort(_ list: [FileTransferContext.RemoteFile]) -> [FileTransferContext.RemoteFile] {
        FileTransferContext.sortedForDisplay(list)
    }

    private func show(sorted list: [FileTransferContext.RemoteFile]) {
        sorted = list
        // A reload reads every file anew; one that is gone is no longer chosen.
        if let chosen = selection { selection = list.first { $0.name == chosen.name && $0.base == chosen.base } }
        applyFilter()
    }

    /// Filtering keeps the order, so typing in the filter never sorts.
    private func applyFilter() {
        let needle = filter.lowercased()
        files = needle.isEmpty ? sorted : sorted.filter { $0.name.lowercased().contains(needle) }
        revision += 1
    }

    private func arrange(_ list: [FileTransferContext.RemoteFile]) {
        listing += 1
        // A long folder is sorted off the main thread; a short one takes less
        // than a frame, and showing it at once avoids a flash of the old one.
        guard list.count > 1000 else { return show(sorted: Self.sort(list)) }
        let expected = listing
        // The published list is only ever read, never mutated in place, so
        // the sort racing a display read is safe.
        nonisolated(unsafe) let list = list
        DispatchQueue.global(qos: .userInitiated).async {
            nonisolated(unsafe) let result = Self.sort(list)
            DispatchQueue.main.async {
                if listing == expected { show(sorted: result) }
            }
        }
    }

    var busy: Bool { context.processConnection || context.isProgressRunning }

    var body: some View {
        PageScaffold(
            scrolls: false,
            primary: ToolbarAction(
                "Download",
                systemImage: "arrow.down.doc",
                primary: true,
                isEnabled: selection != nil && !busy && context.connected
            ) {
                if let selection { download(selection) }
            }
        ) {
            ToolbarAction("Enclosing Folder", systemImage: "arrow.up") { goUp() }
                .disabled(context.currentUrl.pathComponents.count <= 1 || busy || !context.connected)
                .keyboardShortcut(.upArrow, modifiers: .command)
            ToolbarAction("Go to Folder", systemImage: "arrow.turn.down.right") { prompt = .goTo }
                .disabled(busy || !context.connected)
                .keyboardShortcut("g", modifiers: [.command, .shift])
        } trailing: {
            ToolbarAction("Reload", systemImage: "arrow.clockwise") { context.loadCurrentFileList() }
                .disabled(busy || !context.connected)
                .keyboardShortcut("r", modifiers: .command)
            ToolbarAction("New Folder", systemImage: "folder.badge.plus") { prompt = .newFolder }
                .disabled(busy || !context.connected)
            ToolbarAction("Upload", systemImage: "arrow.up.doc") { upload() }
                .disabled(busy || !context.connected)
            ToolbarAction("Close Files", systemImage: "xmark") {
                FileTransferSessionActions.close(context)
            }
        } header: {
            VStack(alignment: .leading, spacing: RX.Space.s2) {
                PageTitle(store.machineRedacted == .all ? "File Transfer" : context.machine.name, subtitle: subtitle)
                HStack(spacing: RX.Space.s3) {
                    Breadcrumb(url: context.currentUrl) { path in
                        context.navigate(path: path)
                    }
                    .disabled(busy || !context.connected)
                    Spacer(minLength: RX.Space.s2)
                    // In the page, not the toolbar: this page stays mounted while
                    // hidden, and a toolbar search field would stay with it.
                    RXSearchField("Filter this folder", text: $filter, width: 200)
                }
            }
        } content: {
            VStack(spacing: RX.Space.s4) {
                if context.destroyedSession || (!context.connected && !context.processConnection) {
                    EmptyStateView(
                        "Connection closed",
                        systemImage: "bolt.horizontal",
                        message: context.connectionPhase == .closed ? "" : context.currentHint,
                        actionTitle: context.destroyedSession ? nil : "Reconnect"
                    ) {
                        context.processBootstrap()
                    }
                    .rxCard()
                    Spacer()
                } else if context.processConnection, context.currentFileList.isEmpty {
                    VStack(spacing: RX.Space.s3) {
                        ProgressView()
                            .rxSpinner()
                        Text(context.currentHint.isEmpty ? "Connecting…" : context.currentHint)
                            .font(.rxBody)
                            .foregroundStyle(.rxInkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(RX.Space.s6)
                    .rxCard()
                    Spacer()
                } else {
                    fileTable
                }
                if context.isProgressRunning, !context.processConnection {
                    transferCard
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                    .strokeBorder(Color.rxAccent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.rxAccentFill.clipShape(RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)))
                    .overlay(
                        Label("Drop to upload to \(context.currentDir)", systemImage: "arrow.up.doc")
                            .font(.rxBodyStrong)
                            .foregroundStyle(.rxAccent)
                    )
                    .padding(RX.Space.s4)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $prompt) { prompt in
            FilePromptSheet(prompt: prompt, context: context) { self.prompt = nil }
        }
        .onChange(of: context.currentDir) { _ in selection = nil }
        .onReceive(context.$currentFileList) { arrange($0) }
        .onChange(of: filter) { _ in applyFilter() }
        #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .benchFiles)) { note in
                if let index = note.userInfo?["select"] as? Int, files.indices.contains(index) { selection = files[index] }
                if let text = note.userInfo?["filter"] as? String { filter = text }
            }
        #endif
        .serverToolSwitcher(machine: context.machine.id, current: .files)
    }

    var subtitle: String {
        store.machineRedacted == .none ? context.machine.getCommand(insertLeadingSSH: false) : ""
    }

    // MARK: Table

    var fileTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TableHeaderLabel("Name").frame(maxWidth: .infinity)
                TableHeaderLabel("Size", alignment: .trailing).frame(width: FileColumns.size)
                Color.clear.frame(width: FileColumns.gap, height: 1)
                TableHeaderLabel("Modified").frame(width: FileColumns.modified)
                TableHeaderLabel("Permissions").frame(width: FileColumns.permissions)
                TableHeaderLabel("Owner").frame(width: FileColumns.owner)
            }
            .padding(.horizontal, RX.Space.s3)
            .frame(height: RX.tableHeaderHeight)
            Hairline()
            if files.isEmpty {
                EmptyStateView(
                    filter.isEmpty ? "Empty folder" : "No matches",
                    systemImage: "folder",
                    message: ""
                )
                Spacer(minLength: 0)
            } else {
                FileTable(
                    files: files,
                    folder: context.currentDir,
                    revision: revision,
                    selection: selection,
                    select: { selection = $0 },
                    open: open,
                    menu: menu(for:)
                )
            }
        }
        .padding(RX.Space.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.clear.rxCard(padding: 0))
        .disabled(busy)
        .opacity(busy ? 0.6 : 1)
    }

    @ViewBuilder
    func menu(for file: FileTransferContext.RemoteFile) -> some View {
        if file.fstat.isDirectory {
            Button("Open") { open(file) }
        } else {
            Button("Edit") { edit(file) }
        }
        Button("Download…") { download(file) }
        Divider()
        Button("Rename…") { prompt = .rename(file.name) }
        Button("Copy Name") { UIBridge.sendPasteboard(str: file.name) }
        Button("Copy Path") {
            UIBridge.sendPasteboard(str: context.currentUrl.appendingPathComponent(file.name).path)
        }
        Divider()
        Button("Delete…", role: .destructive) { delete(file) }
    }

    // MARK: Transfer card

    var transferCard: some View {
        let total = context.totalProgress
        let current = context.currentProgress
        let fraction: Double? = total.totalUnitCount > 0
            ? total.fractionCompleted
            : (current.totalUnitCount > 0 ? current.fractionCompleted : nil)
        var detail: [String] = []
        if total.totalUnitCount > 1 {
            detail.append("\(total.completedUnitCount) of \(total.totalUnitCount)")
        }
        if context.currentSpeed > 0 {
            detail.append(RXFormat.rateString(Double(context.currentSpeed)))
        }
        let name = context.currentProcessingFile.isEmpty
            ? (context.currentHint.isEmpty ? "Working…" : context.currentHint)
            : URL(fileURLWithPath: context.currentProcessingFile).lastPathComponent
        return VStack(alignment: .leading, spacing: RX.Space.s2) {
            CardHead("Transfer")
            ProgressRowView(
                title: name,
                detail: detail.joined(separator: " · "),
                fraction: fraction,
                cancel: context.currentProgressCancelable && context.continueCurrentProgress
                    ? { context.continueCurrentProgress = false }
                    : nil
            )
        }
        .rxCard()
    }

    // MARK: Actions

    func goUp() {
        context.navigate(path: context.currentUrl.deletingLastPathComponent().path)
    }

    func open(_ file: FileTransferContext.RemoteFile) {
        if file.fstat.isDirectory {
            context.navigate(path: context.currentUrl.appendingPathComponent(file.name).path)
        } else if Int64(truncating: file.fstat.size ?? 0) <= FileTransferContext.editableSizeLimit {
            edit(file)
        } else {
            download(file)
        }
    }

    func edit(_ file: FileTransferContext.RemoteFile) {
        AppRouter.shared.openEditor(context: context, path: context.currentUrl.appendingPathComponent(file.name).path)
    }

    func upload() {
        UIBridge.openPanel(
            message: "Upload to \(context.currentDir)",
            prompt: "Upload",
            directory: nil,
            canChooseFiles: true,
            canChooseDirectories: true,
            allowsMultipleSelection: true,
            canCreateDirectories: false,
            showsHiddenFiles: false
        ) { urls in
            if !urls.isEmpty { context.upload(urls: urls) }
        }
    }

    func download(_ file: FileTransferContext.RemoteFile) {
        let remote = context.currentUrl.appendingPathComponent(file.name)
        UIBridge.openPanel(
            message: "Choose where to save \(file.name)",
            prompt: "Download Here",
            directory: nil,
            canChooseFiles: false,
            canChooseDirectories: true,
            allowsMultipleSelection: false,
            canCreateDirectories: true,
            showsHiddenFiles: false
        ) { urls in
            if let url = urls.first { context.download(from: remote, toDir: url) }
        }
    }

    func delete(_ file: FileTransferContext.RemoteFile) {
        let item = context.currentUrl.appendingPathComponent(file.name)
        UIBridge.requiresConfirmation(
            message: "Delete \(file.name)?",
            informative: file.fstat.isDirectory
                ? "The folder and everything in it is deleted from the server. This cannot be undone."
                : "The file is deleted from the server. This cannot be undone.",
            confirmTitle: "Delete",
            destructive: true
        ) { confirmed in
            if confirmed { context.delete(item: item) }
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard context.connected, !busy else { return false }
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        // Say no to a drop with nothing we can take, so it lands elsewhere.
        guard !matching.isEmpty else { return false }
        let group = DispatchGroup()
        let urls = DroppedURLs()
        for provider in matching {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.values.isEmpty { context.upload(urls: urls.values) }
        }
        return true
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

/// The current remote folder: one clickable segment per folder, the last in `ink` semibold.
/// Long paths collapse middle segments into "…".
struct Breadcrumb: View {
    let url: URL
    let navigate: (String) -> Void

    var body: some View {
        let components = url.pathComponents
        let indices = Array(components.indices)
        let shown: [Int?] = indices.count > 5
            ? [indices[0], nil] + indices.suffix(3).map { Optional($0) }
            : indices.map { Optional($0) }
        HStack(spacing: 2) {
            ForEach(Array(shown.enumerated()), id: \.offset) { position, index in
                if position > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.rxInkTertiary)
                }
                if let index {
                    let isLast = index == components.count - 1
                    Button {
                        navigate(path(upTo: index))
                    } label: {
                        Text(components[index])
                            .font(.system(size: 13, weight: isLast ? .semibold : .regular))
                            .foregroundStyle(isLast ? Color.rxInk : Color.rxInkSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLast)
                } else {
                    Text("…").foregroundStyle(.rxInkSecondary)
                }
            }
        }
        .layoutPriority(1)
    }

    func path(upTo index: Int) -> String {
        let components = url.pathComponents.prefix(index + 1)
        guard components.count > 1 else { return "/" }
        return "/" + components.dropFirst().joined(separator: "/")
    }
}

// MARK: - Prompts

enum FilePrompt: Identifiable {
    case goTo
    case newFolder
    case rename(String)

    var id: String {
        switch self {
        case .goTo: return "goto"
        case .newFolder: return "folder"
        case let .rename(name): return "rename-\(name)"
        }
    }
}

/// Go to Folder, New Folder and Rename as small sheets.
private struct FilePromptSheet: View {
    let prompt: FilePrompt
    @ObservedObject var context: FileTransferContext
    let close: () -> Void

    @State private var text = ""

    var title: String {
        switch prompt {
        case .goTo: return "Go to Folder"
        case .newFolder: return "New Folder"
        case .rename: return "Rename"
        }
    }

    var error: String? {
        switch prompt {
        case .goTo:
            return text.hasPrefix("/") || text.isEmpty ? nil : "Use an absolute path starting with /."
        case .newFolder, .rename:
            if text.isEmpty { return nil }
            if !text.isValidAsFilename { return "That name contains characters a file name cannot have." }
            if case let .rename(original) = prompt, original == text { return nil }
            if context.currentFileList.contains(where: { $0.name == text }) { return "“\(text)” already exists in this folder." }
            return nil
        }
    }

    var body: some View {
        SheetScaffold(title) {
            RXField(prompt.label, error: error) {
                TextField(prompt.placeholder, text: $text)
                    .textFieldStyle(prompt.isPath ? .rxMono : .rx)
                    .disableAutocorrection(true)
                    .onSubmit(confirm)
            }
        } footer: {
            Spacer()
            Button("Cancel", action: close)
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Button(prompt.confirmTitle, action: confirm)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(text.isEmpty || error != nil)
        }
        .frame(width: 420)
        .onAppear {
            switch prompt {
            case .goTo: text = context.currentDir
            case .newFolder: text = ""
            case let .rename(name): text = name
            }
        }
    }

    func confirm() {
        guard !text.isEmpty, error == nil else { return }
        switch prompt {
        case .goTo:
            context.navigate(path: text)
        case .newFolder:
            context.createFolder(with: text)
        case let .rename(original):
            if original != text {
                let base = context.currentUrl
                context.rename(from: base.appendingPathComponent(original), to: base.appendingPathComponent(text))
            }
        }
        close()
    }
}

private extension FilePrompt {
    var label: String {
        switch self {
        case .goTo: return "Path"
        case .newFolder, .rename: return "Name"
        }
    }

    var placeholder: String {
        switch self {
        case .goTo: return "/var/log"
        case .newFolder: return "untitled folder"
        case .rename: return "Name"
        }
    }

    var confirmTitle: String {
        switch self {
        case .goTo: return "Go"
        case .newFolder: return "Create"
        case .rename: return "Rename"
        }
    }

    var isPath: Bool {
        if case .goTo = self { return true }
        return false
    }
}

enum FileTransferSessionActions {
    /// Closes a server's SFTP session, and with it the editor that works over it.
    @MainActor
    static func close(_ context: FileTransferContext) {
        let unsaved = EditorCenter.shared.workspaces.first { $0.id == context.id }?.hasUnsavedChanges == true
        if context.isProgressRunning || unsaved {
            UIBridge.requiresConfirmation(
                message: "Close the file transfer on \(context.machine.name)?",
                informative: unsaved
                    ? "Files open in the editor have changes that are not saved. They are lost if you close."
                    : "A transfer is still running and will be interrupted.",
                confirmTitle: unsaved ? "Discard Changes" : "Close",
                destructive: true,
                always: unsaved
            ) { confirmed in
                if confirmed { FileTransferManager.shared.end(for: context.id) }
            }
        } else {
            FileTransferManager.shared.end(for: context.id)
        }
    }
}
