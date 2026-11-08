//
//  EditSnippetView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/3.
//

import CatusshEditor
import CatusshModule
import SwiftUI
import SymbolPicker

struct EditSnippetView: View {
    @Environment(\.dismiss) private var dismiss

    let inEditWith: UUID?

    @State var name: String
    @State var group: String
    @State var code: String
    @State var comment: String
    @State var avatar: String
    @State var openSymbolPicker: Bool = false

    init(requestSnippet: UUID? = nil) {
        inEditWith = requestSnippet
        if let edit = requestSnippet {
            let read = CatusshStore.shared.snippetGroup[edit]
            _name = State(initialValue: read.name)
            _group = State(initialValue: read.group)
            _code = State(initialValue: read.code.isEmpty ? "#!/bin/bash\n\n" : read.code)
            _comment = State(initialValue: read.comment)
            _avatar = State(initialValue: read.getSFAvatar())
        } else {
            _name = State(initialValue: "")
            _group = State(initialValue: "")
            _code = State(initialValue: "#!/bin/bash\n\n")
            _comment = State(initialValue: "")
            _avatar = State(initialValue: "")
        }
    }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name)
                Button {
                    openSymbolPicker = true
                } label: {
                    if avatar.isEmpty {
                        Text("Select SF Symbol")
                    } else {
                        Label("Select SF Symbol", systemImage: avatar.isEmpty ? "square.dashed" : avatar)
                    }
                }
                TextField("Group", text: $group)
                TextField("Comment", text: $comment)
            } header: {
                RXSectionHeader("Name")
            }

            Section {
                CodeEditor(
                    text: $code,
                    language: .bash,
                    wrapsLines: true,
                    fontSize: CGFloat(CatusshStore.shared.terminalFontSize)
                )
                .frame(height: 250)
            } header: {
                RXSectionHeader("Code")
            }

            if let identity = inEditWith {
                Section {
                    Button {
                        UIBridge.requiresConfirmation(
                            message: "Delete this snippet?"
                        ) { confirmed in
                            if confirmed {
                                CatusshStore.shared.snippetGroup.delete(identity)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("Delete Snippet", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $openSymbolPicker, onDismiss: nil) {
            SymbolPicker(symbol: $avatar)
        }
        .rxGroupedList()
        .navigationTitle(inEditWith == nil ? "New Snippet" : "Edit Snippet")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    completeSheet()
                } label: {
                    Text("Save").bold()
                }
            }
        }
    }

    func completeSheet() {
        guard !name.isEmpty else {
            UIBridge.presentError(with: "Empty Name")
            return
        }

        let id = inEditWith ?? UUID()

        var newSnippet = RDSnippet(
            id: id,
            name: name,
            group: group,
            code: code,
            comment: comment,
            attachment: [:]
        )
        if avatar.isEmpty {
            newSnippet.clearSFAvatar()
        } else {
            newSnippet.setSFAvatar(sfSymbol: avatar)
        }

        CatusshStore.shared.snippetGroup.insert(newSnippet)

        dismiss()
    }
}

struct EditSnippetView_Previews: PreviewProvider {
    static var previews: some View {
        createPreview { AnyView(EditSnippetView()) }
    }
}
