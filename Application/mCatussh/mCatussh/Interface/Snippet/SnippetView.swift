//
//  SnippetView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//

import CatusshModule
import SwiftUI

struct SnippetView: View {
    @EnvironmentObject var store: CatusshStore
    @State private var searchKey = ""
    @State private var openCreate = false
    @State private var groupFilter: String?

    var groupNames: [String] {
        Set(store.snippetGroup.snippets.map(\.group)).filter { !$0.isEmpty }.sorted()
    }

    var filtered: [RDSnippet] {
        var all = store.snippetGroup.snippets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let groupFilter {
            all = all.filter { $0.group == groupFilter }
        }
        guard !searchKey.isEmpty else { return all }
        return all.filter { $0.isQualifiedForSearch(text: searchKey.lowercased()) }
    }

    var body: some View {
        Group {
            if store.snippetGroup.snippets.isEmpty {
                EmptyStateView(
                    "No snippets yet",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    actionTitle: "New Snippet"
                ) {
                    openCreate = true
                }
                .frame(maxHeight: .infinity)
                .background(RXBackdrop().ignoresSafeArea())
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: RX.Space.s3, alignment: .top)], spacing: RX.Space.s3) {
                        ForEach(filtered) { snippet in
                            SnippetElementView(identity: snippet.id)
                        }
                    }
                    .padding(RX.Space.s4)
                }
                .background(RXBackdrop().ignoresSafeArea())
                .searchable(text: $searchKey, prompt: "Search snippets")
            }
        }
        .navigationTitle("Snippets")
        .toolbar {
            ToolbarItemGroup {
                if !groupNames.isEmpty {
                    Menu {
                        Picker("Group", selection: $groupFilter) {
                            Text("All Groups").tag(String?.none)
                            ForEach(groupNames, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    } label: {
                        Label("Filter by Group", systemImage: groupFilter == nil
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                Button {
                    openCreate = true
                } label: {
                    Label("New Snippet", systemImage: "plus")
                }
            }
        }
        .onChange(of: groupNames) { names in
            if let groupFilter, !names.contains(groupFilter) { self.groupFilter = nil }
        }
        .sheet(isPresented: $openCreate) {
            NavigationStack { EditSnippetView() }
        }
    }
}
