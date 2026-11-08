//
//  EditorPage.swift
//  catussh (macOS)
//
//  A server's text files, edited in place: tabs for the open files, the code
//  editor, and a status line with the syntax, the caret and what is unsaved.
//  Open File, Wrap Lines, Reload, Close and Save (⌘S) are in the toolbar.
//

import CatusshEditor
import CatusshModule
import SwiftUI

struct EditorPage: View {
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var context: FileTransferContext
    @EnvironmentObject var store: CatusshStore
    @Environment(\.isActivePage) private var isActive

    @AppStorage("me.mizorewww.rayon.editor.wrapsLines") private var wrapsLines = false
    @State private var openPrompt = false
    @Namespace private var tabs

    init(workspace: EditorWorkspace) {
        self.workspace = workspace
        context = workspace.context
    }

    private var current: EditorDocument? { workspace.current }

    var body: some View {
        PageScaffold(
            scrolls: false,
            primary: ToolbarAction(
                "Save",
                systemImage: "square.and.arrow.down",
                primary: true,
                isEnabled: current?.isEdited == true && current?.saving == false
            ) {
                current?.save()
            }
        ) {
        } trailing: {
            ToolbarAction("Open File…", systemImage: "doc.badge.plus") { openPrompt = true }
                .keyboardShortcut("o", modifiers: .command)
            ToolbarAction(wrapsLines ? "Don't Wrap Lines" : "Wrap Lines", systemImage: wrapsLines ? "text.justify.leading" : "text.word.spacing") {
                wrapsLines.toggle()
            }
            ToolbarAction("Reload from Server", systemImage: "arrow.clockwise") { reload() }
                .disabled(current == nil || current?.phase == .loading)
            ToolbarAction("Close Editor", systemImage: "xmark") { EditorSessionActions.close(workspace) }
        } header: {
            PageTitle(store.machineRedacted == .all ? "Editor" : context.machine.name, subtitle: subtitle)
        } content: {
            if workspace.documents.isEmpty {
                VStack(spacing: RX.Space.s4) {
                    EmptyStateView(
                        "No file open",
                        systemImage: "square.and.pencil",
                        message: "Double-click a text file in Files, or open one by its path.",
                        actionTitle: "Open File…"
                    ) {
                        openPrompt = true
                    }
                    .rxCard()
                    Spacer()
                }
                .transition(.opacity)
            } else {
                editor
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: workspace.documents.isEmpty)
        .background {
            // ⌘S and ⌘W act on the page in front only.
            if isActive {
                Group {
                    Button("Save") { current?.save() }
                        .keyboardShortcut("s", modifiers: .command)
                    Button("Close File") { if let current { workspace.close(current) } }
                        .keyboardShortcut("w", modifiers: .command)
                        .disabled(current == nil)
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $openPrompt) {
            OpenRemoteFileSheet(folder: context.currentDir) { path in
                workspace.open(path: path)
            }
        }
        .serverToolSwitcher(machine: context.machine.id, current: .editor)
    }

    private var subtitle: String {
        store.machineRedacted == .none ? context.machine.getCommand(insertLeadingSSH: false) : ""
    }

    // MARK: Editor

    private var editor: some View {
        VStack(spacing: 0) {
            tabStrip
            Hairline()
            // Render the active document so background NSTextViews do not pollute the accessibility tree.
            Group {
                if let current {
                    EditorSurface(document: current, wrapsLines: wrapsLines)
                        .id(current.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let current {
                Hairline()
                EditorStatusLine(document: current, caret: current.caret)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rxCardChrome()
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(workspace.documents) { document in
                        EditorTab(
                            document: document,
                            selected: document.id == workspace.selection,
                            namespace: tabs,
                            select: { workspace.selection = document.id },
                            close: { workspace.close(document) }
                        )
                        .id(document.id)
                        .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, RX.Space.s2)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: workspace.documents.map(\.id))
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: workspace.selection)
            }
            .frame(height: 36)
            .onChange(of: workspace.selection) { selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selected) }
            }
        }
    }

    private func reload() {
        guard let current else { return }
        guard current.isEdited else { return current.load() }
        UIBridge.requiresConfirmation(
            message: "Reload \(current.name) from the server?",
            informative: "Your changes are replaced by the file on the server.",
            confirmTitle: "Reload",
            destructive: true,
            always: true
        ) { confirmed in
            MainActor.assumeIsolated {
                if confirmed { current.load() }
            }
        }
    }
}

// MARK: - Tabs

private struct EditorTab: View {
    @ObservedObject var document: EditorDocument
    let selected: Bool
    let namespace: Namespace.ID
    let select: () -> Void
    let close: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: RX.Space.s1) {
            Button(action: select) {
                Text(document.name)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.rxInk : Color.rxInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
                    .padding(.leading, RX.Space.s3)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(document.path)
            .accessibilityAddTraits(selected ? .isSelected : [])

            ZStack {
                if hovered || (selected && !document.isEdited) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.rxInkSecondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close \(document.name)")
                    .transition(.opacity)
                } else if document.isEdited {
                    Circle()
                        .fill(Color.rxInkSecondary)
                        .frame(width: 7, height: 7)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Edited")
                }
            }
            .frame(width: 16, height: 16)
            .padding(.trailing, RX.Space.s1)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.15), value: document.isEdited)
        }
        .frame(height: 26)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                    .fill(Color.rxRowSelected)
                    .matchedGeometryEffect(id: "selection", in: namespace)
            } else if hovered {
                RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                    .fill(Color.rxRowHover)
            }
        }
        .onHover { hovered = $0 }
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
                VStack(spacing: RX.Space.s3) {
                    ProgressView()
                        .rxSpinner()
                    Text("Opening \(document.name)…")
                        .font(.rxBody)
                        .foregroundStyle(.rxInkSecondary)
                }
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

/// Syntax, caret position, the file's folder, and whether it has unsaved changes.
private struct EditorStatusLine: View {
    @ObservedObject var document: EditorDocument
    @ObservedObject var caret: EditorCaretPosition

    var body: some View {
        HStack(spacing: RX.Space.s3) {
            Picker("Syntax", selection: $document.language) {
                ForEach(EditorLanguage.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Syntax highlighting")
            Text("Ln \(caret.value.line), Col \(caret.value.column)")
                .monospacedDigit()
            Text(document.path)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if document.saving {
                Text("Saving…")
                    .transition(.opacity)
            } else if document.isEdited {
                Text("Edited")
                    .foregroundStyle(.rxWarning)
                    .transition(.opacity)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.rxInkSecondary)
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 28)
        .animation(.easeOut(duration: 0.15), value: document.isEdited)
        .animation(.easeOut(duration: 0.15), value: document.saving)
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
        SheetScaffold("Open File", lead: "A text file on the server, up to 4 MB.") {
            RXField("Path", error: error) {
                TextField("/etc/hosts", text: $path)
                    .textFieldStyle(.rxMono)
                    .disableAutocorrection(true)
                    .onSubmit(confirm)
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Open", action: confirm)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!isFile)
        }
        .frame(width: 420)
        .onAppear { path = folder.hasSuffix("/") ? folder : folder + "/" }
    }

    private func confirm() {
        guard isFile else { return }
        open(path)
        dismiss()
    }
}
