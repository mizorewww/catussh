//
//  RemoteFileEditorView.swift
//  mCatussh
//
//  Edits a text file on the server using the shared EditorDocument in CatusshModule.
//

import CatusshEditor
import CatusshModule
import SwiftUI

struct RemoteFileEditorView: View {
    @ObservedObject var context: FileTransferContext
    let remotePath: String

    @StateObject private var document: EditorDocument
    @ObservedObject private var caret: EditorCaretPosition
    @Environment(\.dismiss) private var dismiss

    @State private var wrapsLines = false
    @State private var saveError: String?
    @State private var confirmClose = false

    init(context: FileTransferContext, remotePath: String) {
        self.context = context
        self.remotePath = remotePath
        let doc = EditorDocument(path: remotePath, context: context)
        _document = StateObject(wrappedValue: doc)
        _caret = ObservedObject(wrappedValue: doc.caret)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(document.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(document.isEdited)
        .confirmationDialog("Save changes to \(document.name)?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Save") {
                document.save { saveError = $0 }
                dismiss()
            }
            Button("Don't Save", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes are lost if you don't save them.")
        }
        .alert("Couldn't Save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        switch document.phase {
        case .loading:
            ProgressView("Opening \(document.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .editing:
            CodeEditor(
                text: Binding(get: { document.text }, set: { document.text = $0 }),
                language: document.language,
                wrapsLines: wrapsLines
            ) { caret.value = $0 }
                .ignoresSafeArea(.container, edges: .bottom)
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        }
    }

    private var statusBar: some View {
        HStack(spacing: RX.Space.s3) {
            Menu {
                Picker("Syntax", selection: $document.language) {
                    ForEach(EditorLanguage.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Text(document.language.title)
            }
            .help("Syntax highlighting")
            Text("Ln \(caret.value.line), Col \(caret.value.column)")
                .monospacedDigit()
            Spacer()
            if document.isEdited {
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

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                if document.isEdited { confirmClose = true } else { dismiss() }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $wrapsLines) {
                Label("Wrap Lines", systemImage: "text.word.spacing")
            }
            .help("Wrap long lines")
            .disabled(document.phase != .editing)
            if document.saving {
                ProgressView()
            } else {
                Button("Save") {
                    document.save { saveError = $0 }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!document.isEdited)
            }
        }
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
