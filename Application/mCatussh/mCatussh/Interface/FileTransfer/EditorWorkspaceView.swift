//
//  EditorWorkspaceView.swift
//  mCatussh
//
//  A server's text files, edited in place, as on the Mac: tabs for the open
//  files (dragged to reorder), the code editor, and a status line with the
//  syntax, the caret, the path and what is unsaved. Open File, Wrap Lines,
//  Reload and Save (⌘S) are in the toolbar. Uses the shared EditorWorkspace
//  in CatusshModule, so the editor stays open under Sessions.
//

import CatusshEditor
import CatusshModule
import SwiftUI
import UniformTypeIdentifiers

/// The editor presented over Files: its own navigation, Done to hide it
/// (it stays under Sessions).
struct EditorWorkspaceScreen: View {
    let workspace: EditorWorkspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EditorWorkspaceView(workspace: workspace)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .tint(.rxAccent)
    }
}

struct EditorWorkspaceView: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var context: FileTransferContext
    @ObservedObject var store = CatusshStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.inServerWorkspace) private var inServerWorkspace

    @AppStorage("me.mizorewww.rayon.editor.wrapsLines") private var wrapsLines = false
    @State private var openPrompt = false
    @State private var saveError: String?
    @State private var draggedDocumentID: EditorDocument.ID?

    init(workspace: EditorWorkspace) {
        self.workspace = workspace
        context = workspace.context
    }

    private var current: EditorDocument? { workspace.current }

    var body: some View {
        Group {
            if workspace.documents.isEmpty {
                EmptyStateView(
                    "No file open",
                    systemImage: "square.and.pencil",
                    message: "Open a text file from Files, or by its path.",
                    actionTitle: "Open File…"
                ) {
                    openPrompt = true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RXBackdrop().ignoresSafeArea())
            } else {
                editor
            }
        }
        .navigationTitle(current?.name ?? (store.machineRedacted == .all ? "Editor" : context.machine.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .background { keyboardShortcuts }
        .sheet(isPresented: $openPrompt) {
            OpenRemoteFileSheet(folder: context.currentDir) { path in
                workspace.open(path: path)
            }
        }
        .alert("Couldn't Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            if workspace.documents.count > 1 {
                tabStrip
                Hairline()
            }
            Group {
                if let current {
                    EditorSurface(document: current, wrapsLines: wrapsLines)
                        .id(current.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let current {
                    EditorStatusLine(document: current, caret: current.caret)
                }
            }
        }
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.documents) { document in
                        EditorTab(
                            document: document,
                            selected: document.id == workspace.selection,
                            select: { workspace.selection = document.id },
                            close: { close(document) }
                        )
                        .id(document.id)
                        .onDrag {
                            draggedDocumentID = document.id
                            return NSItemProvider(object: document.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: EditorTabDropDelegate(
                                targetID: document.id,
                                draggedID: $draggedDocumentID,
                                workspace: workspace
                            )
                        )
                    }
                }
                .padding(.horizontal, RX.Space.s2)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: workspace.documents.map(\.id))
            }
            .frame(height: 40)
            .background(Color.rxSurface)
            .onChange(of: workspace.selection) { selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selected) }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if current?.saving == true {
                ProgressView()
            } else {
                Button {
                    save()
                } label: {
                    Text("Save").bold()
                }
                .disabled(current?.isEdited != true)
            }
            Menu {
                Section {
                    Button { openPrompt = true } label: {
                        Label("Open File…", systemImage: "doc.badge.plus")
                    }
                    Button { reload() } label: {
                        Label("Reload from Server", systemImage: "arrow.clockwise")
                    }
                    .disabled(current == nil || current?.phase == .loading)
                    Toggle(isOn: $wrapsLines) {
                        Label("Wrap Lines", systemImage: "text.word.spacing")
                    }
                }
                if let current {
                    Section {
                        Button { close(current) } label: {
                            Label("Close \(current.name)", systemImage: "xmark")
                        }
                    }
                }
                Section {
                    Button(role: .destructive) { closeEditor() } label: {
                        Label("Close Editor", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    /// iPad hardware keyboard: ⌘S, ⌘O and ⌘W act on the editor in front.
    private var keyboardShortcuts: some View {
        Group {
            Button("Save") { save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Open File…") { openPrompt = true }
                .keyboardShortcut("o", modifiers: .command)
            Button("Close File") { if let current { close(current) } }
                .keyboardShortcut("w", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private func save() {
        current?.save { saveError = $0 }
    }

    private func close(_ document: EditorDocument) {
        guard document.isEdited else { return workspace.remove(document) }
        UIBridge.requiresConfirmation(
            message: "Close \(document.name) without saving?",
            informative: "Your changes are lost if you don't save them.",
            confirmTitle: "Discard Changes",
            always: true
        ) { confirmed in
            MainActor.assumeIsolated {
                if confirmed { workspace.remove(document) }
            }
        }
    }

    private func closeEditor() {
        let end = {
            // On a server's page, the page stays for its other tools.
            if !inServerWorkspace { dismiss() }
            EditorCenter.shared.end(workspace.id)
        }
        guard workspace.hasUnsavedChanges else { return end() }
        UIBridge.requiresConfirmation(
            message: "Close the editor on \(context.machine.name)?",
            informative: "Some files have changes that are not saved. They are lost if you close the editor.",
            confirmTitle: "Discard Changes",
            always: true
        ) { confirmed in
            if confirmed { MainActor.assumeIsolated { end() } }
        }
    }

    private func reload() {
        guard let current else { return }
        guard current.isEdited else { return current.load() }
        UIBridge.requiresConfirmation(
            message: "Reload \(current.name) from the server?",
            informative: "Your changes are replaced by the file on the server.",
            confirmTitle: "Reload",
            always: true
        ) { confirmed in
            MainActor.assumeIsolated {
                if confirmed { current.load() }
            }
        }
    }
}

// MARK: - Tabs

private struct EditorTabDropDelegate: DropDelegate {
    let targetID: EditorDocument.ID
    @Binding var draggedID: EditorDocument.ID?
    let workspace: EditorWorkspace

    func dropEntered(info _: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        withAnimation(.rxQuick) {
            workspace.moveDocument(fromID: draggedID, toID: targetID)
        }
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}

private struct EditorTab: View {
    @ObservedObject var document: EditorDocument
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: RX.Space.s1) {
            Button(action: select) {
                Text(document.name)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.rxInk : Color.rxInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
                    .padding(.leading, RX.Space.s3)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            ZStack {
                if document.isEdited, !selected {
                    Circle()
                        .fill(Color.rxInkSecondary)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Edited")
                } else {
                    Button(action: close) {
                        Image(systemName: document.isEdited ? "circle.fill" : "xmark")
                            .font(.system(size: document.isEdited ? 7 : 9, weight: .bold))
                            .foregroundStyle(.rxInkSecondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close \(document.name)")
                }
            }
            .frame(width: 22, height: 22)
            .padding(.trailing, RX.Space.s1)
        }
        .frame(height: 30)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                    .fill(Color.rxRowSelected)
            }
        }
        .contextMenu {
            Button { UIBridge.sendPasteboard(str: document.path) } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
            Button(role: .destructive, action: close) {
                Label("Close", systemImage: "xmark")
            }
        }
    }
}

// MARK: - Surface

/// One file: opening, the editor, or why it could not be opened.
private struct EditorSurface: View {
    @ObservedObject var document: EditorDocument
    let wrapsLines: Bool

    var body: some View {
        ZStack {
            switch document.phase {
            case .loading:
                ProgressView("Opening \(document.name)…")
                    .transition(.opacity)
            case let .failed(message):
                EmptyStateView(
                    "Can't open \(document.name)",
                    systemImage: "doc.badge.ellipsis",
                    message: message,
                    actionTitle: "Try Again"
                ) {
                    document.load()
                }
                .padding(RX.Space.s4)
                .transition(.opacity)
            case .editing:
                CodeEditor(
                    text: Binding(get: { document.text }, set: { document.text = $0 }),
                    language: document.language,
                    wrapsLines: wrapsLines
                ) { [caret = document.caret] in
                    caret.value = $0
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: document.phase)
    }
}

/// Syntax, caret position, the file's path, and whether it has unsaved changes.
private struct EditorStatusLine: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var caret: EditorCaretPosition

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            Menu {
                Picker("Syntax", selection: $document.language) {
                    ForEach(EditorLanguage.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Text(document.language.title)
            }
            .accessibilityLabel("Syntax highlighting")
            Text("Ln \(caret.value.line), Col \(caret.value.column)")
                .monospacedDigit()
            Text(document.path)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if document.saving {
                Text("Saving…")
            } else if document.isEdited {
                Text("Edited")
                    .foregroundStyle(.rxWarning)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.rxInkSecondary)
        .padding(.horizontal, RX.Space.s4)
        .frame(height: 30)
        .background(.bar)
    }
}

// MARK: - Open by path

private struct OpenRemoteFileSheet: View {
    let folder: String
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""

    private var error: String? {
        if path.isEmpty || path.hasPrefix("/") { return nil }
        return "Use an absolute path starting with /."
    }

    private var isFile: Bool { path.hasPrefix("/") && !path.hasSuffix("/") }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("/etc/hosts", text: $path)
                        .font(.rxCode)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .submitLabel(.go)
                        .onSubmit(confirm)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.rxDanger)
                    } else {
                        Text("A text file on the server, up to 4 MB.")
                    }
                }
            }
            .navigationTitle("Open File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open", action: confirm)
                        .disabled(!isFile)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { path = folder.hasSuffix("/") ? folder : folder + "/" }
    }

    private func confirm() {
        guard isFile else { return }
        open(path)
        dismiss()
    }
}

#if DEBUG
    struct EditorPreviewScreen: View {
        @State private var text = """
        #!/usr/bin/env bash
        # Rotate logs and restart the service.
        set -euo pipefail

        LOG_DIR="/var/log/web"
        KEEP=7

        rotate() {
            local file="$1"
            if [[ -s "$file" ]]; then
                mv "$file" "$file.$(date +%Y%m%d)"
            fi
        }

        for log in "$LOG_DIR"/*.log; do
            rotate "$log"
        done
        find "$LOG_DIR" -name '*.log.*' -mtime +"$KEEP" -delete
        systemctl restart web.service   # pick up new log handles
        """
        @State private var caret = EditorCaret(line: 1, column: 1)

        var body: some View {
            NavigationStack {
                CodeEditor(text: $text, language: .bash) { caret = $0 }
                    .navigationTitle("rotate-logs.sh")
                    .navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        HStack {
                            Text("Shell")
                            Text("Ln \(caret.line), Col \(caret.column)").monospacedDigit()
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.rxInkSecondary)
                        .padding(.horizontal, RX.Space.s4)
                        .frame(height: 30)
                        .background(.bar)
                    }
            }
        }
    }
#endif
