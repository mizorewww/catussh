//
//  LogView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/14.
//

import CatusshModule
import SwiftUI

struct LogView: View {
    @State private var lines: [String] = []
    @State private var searchText: String = ""

    private var filteredLines: [String] {
        guard !searchText.isEmpty else { return lines }
        return lines.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            if filteredLines.isEmpty {
                Text("No diagnostic entries")
                    .font(.rxCode)
                    .foregroundStyle(.rxInkSecondary)
            } else {
                ForEach(Array(filteredLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.rxInk)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button {
                                UIBridge.sendPasteboard(str: line)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Filter logs")
        .refreshable {
            await reloadLogs()
        }
        .task {
            await reloadLogs()
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("Diagnostic")
        .toolbar {
            ToolbarItem {
                Button {
                    if let url = LogRedirect.shared.path {
                        DispatchQueue.global().async {
                            guard let data = try? Data(contentsOf: url) else { return }
                            let str = String(decoding: data, as: UTF8.self)
                            guard !str.isEmpty else { return }
                            onMainThread {
                                UIBridge.sendPasteboard(str: str)
                            }
                        }
                    }
                } label: {
                    Label("Share Diagnostic Data", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private func reloadLogs() async {
        guard let url = LogRedirect.shared.path else { return }
        let loaded: [String] = await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
            let maxBytes: UInt64 = 1024 * 1024
            let fileSize = (try? handle.seekToEnd()) ?? 0
            let startOffset = fileSize > maxBytes ? (fileSize - maxBytes) : 0
            try? handle.seek(toOffset: startOffset)
            let data = (try? handle.readToEnd()) ?? Data()
            // String(decoding:as:) safely replaces any truncated multi-byte UTF-8 sequence at startOffset
            let text = String(decoding: data, as: UTF8.self)
            var split = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            if startOffset > 0, !split.isEmpty {
                split.removeFirst()
            }
            return Array(split.reversed().prefix(4096))
        }.value
        lines = loaded
    }
}
