//
//  SnippetElementView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//

import CatusshModule
import SwiftUI

/// A snippet card: its SF Symbol, name, group and comment, the command on `terminal-bg`.
struct SnippetElementView: View {
    @EnvironmentObject var store: CatusshStore
    let identity: RDSnippet.ID
    @State private var openEdit = false

    var snippet: RDSnippet { store.snippetGroup[identity] }

    var detail: String {
        [snippet.group, snippet.comment].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            HStack(alignment: .top, spacing: RX.Space.s3) {
                SymbolTile(snippet.getSFAvatar())
                VStack(alignment: .leading, spacing: 2) {
                    Text(snippet.name.isEmpty ? "Untitled" : snippet.name)
                        .font(.headline)
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        HelpText(detail).lineLimit(1)
                    }
                }
                Spacer()
                Menu {
                    Button {
                        guard !snippet.code.isEmpty else {
                            UIBridge.presentError(with: "This snippet has no command to run.")
                            return
                        }
                        CatusshUtil.createExecuteFor(snippet: snippet)
                    } label: {
                        Label("Run…", systemImage: "play")
                    }
                    Button {
                        openEdit = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button {
                        var copy = snippet
                        copy.id = .init()
                        store.snippetGroup.insert(copy)
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    Button {
                        UIBridge.sendPasteboard(str: snippet.code)
                    } label: {
                        Label("Copy Command", systemImage: "doc.on.doc")
                    }
                    Divider()
                    Button(role: .destructive) {
                        UIBridge.requiresConfirmation(message: "Delete \(snippet.name)?") { confirmed in
                            if confirmed { store.snippetGroup.delete(identity) }
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 28)
                        .foregroundStyle(.rxInkSecondary)
                }
                .accessibilityLabel("Actions")
            }
            CodeBlock(snippet.code.trimmingCharacters(in: .whitespacesAndNewlines), lineLimit: 4)
        }
        .rxCard()
        .contentShape(Rectangle())
        .onTapGesture { openEdit = true }
        .sheet(isPresented: $openEdit) {
            NavigationStack { EditSnippetView(requestSnippet: identity) }
        }
    }
}
