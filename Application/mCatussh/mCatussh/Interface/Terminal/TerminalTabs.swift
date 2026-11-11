//
//  TerminalTabs.swift
//  mCatussh
//
//  The tabs of a server's terminals, as on the Mac: tabs split together sit
//  in one pill with a badge that switches the split between side by side
//  and stacked; a tab is dragged to reorder, or onto the terminal to split.
//  And the snippets to insert into or run in the terminal in front.
//

import CatusshModule
import SwiftUI
import UniformTypeIdentifiers

struct TerminalTabStrip: View {
    @ObservedObject var current: TerminalContext
    @Binding var draggedTabID: TerminalContext.ID?
    /// Splits are offered only where panes can show side by side.
    let canSplit: Bool
    let select: (TerminalContext.ID) -> Void
    let newTab: () -> Void
    @ObservedObject var terminals = TerminalManager.shared

    var body: some View {
        HStack(spacing: RX.Space.s1) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        let totalCount = current.tabSiblings.count
                        ForEach(terminals.tabClusters(for: current)) { cluster in
                            if let group = cluster.group {
                                groupedCluster(group: group, items: cluster.items, totalCount: totalCount)
                            } else if let single = cluster.items.first {
                                tabItem(index: single.index, context: single.context, totalCount: totalCount, inSplitGroup: false)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { reader.scrollTo(current.id) }
                .onChange(of: current.id) { id in withAnimation(.rxQuick) { reader.scrollTo(id) } }
            }
            if current.remoteType != .local {
                Button(action: newTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.rxInkSecondary)
                .accessibilityLabel("New Terminal Tab")
            }
        }
    }

    @ViewBuilder
    private func groupedCluster(
        group: TerminalManager.SplitGroup,
        items: [(index: Int, context: TerminalContext)],
        totalCount: Int
    ) -> some View {
        let isActiveGroup = items.contains { $0.context.id == current.id }
        HStack(spacing: 2) {
            // The split badge: orientation and pane count; tap to switch.
            Button {
                let next: TerminalManager.SplitOrientation = group.orientation == .horizontal ? .vertical : .horizontal
                if let firstID = items.first?.context.id {
                    withAnimation(.rxQuick) { terminals.setSplitOrientation(for: firstID, orientation: next) }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: group.orientation == .horizontal ? "rectangle.split.2x1.fill" : "rectangle.split.1x2.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(isActiveGroup ? Color.rxAccent : Color.rxInkSecondary)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background(
                    Capsule()
                        .fill(isActiveGroup ? Color.rxAccent.opacity(0.18) : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Split group (\(items.count) panes) · Tap to switch horizontal/vertical")
            .padding(.leading, 3)

            ForEach(items, id: \.context.id) { item in
                tabItem(index: item.index, context: item.context, totalCount: totalCount, inSplitGroup: true)
            }
        }
        .padding(2)
        .background(
            Capsule()
                .fill(isActiveGroup ? Color.rxAccent.opacity(0.09) : Color.primary.opacity(0.04))
        )
        .overlay(
            Capsule()
                .strokeBorder(isActiveGroup ? Color.rxAccent.opacity(0.55) : Color.rxHairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func tabItem(index: Int, context: TerminalContext, totalCount: Int, inSplitGroup: Bool) -> some View {
        let isVisibleInSplit = canSplit && terminals.splitGroup(containing: current.id)?.memberIDs.contains(context.id) == true
        let isCurrent = context.id == current.id
        TerminalTab(
            context: context,
            selected: isCurrent,
            visibleInSplit: isVisibleInSplit && !isCurrent,
            inSplitGroup: inSplitGroup,
            number: totalCount > 1 ? index + 1 : nil,
            select: { select(context.id) },
            onSplitRight: !canSplit || isCurrent ? nil : {
                withAnimation(.rxQuick) {
                    terminals.groupSessions(anchorID: current.id, newID: context.id, orientation: .horizontal)
                }
            },
            onSplitDown: !canSplit || isCurrent ? nil : {
                withAnimation(.rxQuick) {
                    terminals.groupSessions(anchorID: current.id, newID: context.id, orientation: .vertical)
                }
            },
            onUngroup: inSplitGroup ? {
                withAnimation(.rxQuick) {
                    terminals.ungroupSession(context.id)
                }
            } : nil
        )
        .id(context.id)
        .onDrag {
            draggedTabID = context.id
            return NSItemProvider(object: context.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: TerminalTabDropDelegate(targetID: context.id, draggedID: $draggedTabID)
        )
    }
}

/// Reorders while a tab is dragged across the others.
private struct TerminalTabDropDelegate: DropDelegate {
    let targetID: TerminalContext.ID
    @Binding var draggedID: TerminalContext.ID?

    func dropEntered(info _: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        withAnimation(.rxQuick) {
            TerminalManager.shared.moveSession(fromID: draggedID, toID: targetID)
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

private struct TerminalTab: View {
    @ObservedObject var context: TerminalContext
    let selected: Bool
    var visibleInSplit = false
    var inSplitGroup = false
    let number: Int?
    let select: () -> Void
    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    var onUngroup: (() -> Void)?

    private var title: String {
        if !context.navigationSubtitle.isEmpty { return context.navigationSubtitle }
        if let number { return "Terminal \(number)" }
        return context.remoteType == .machine ? "Terminal" : context.displayName
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: select) {
                HStack(spacing: 6) {
                    if inSplitGroup {
                        Circle()
                            .fill(selected ? Color.rxAccent : (visibleInSplit ? Color.rxAccent.opacity(0.45) : Color.rxInkTertiary))
                            .frame(width: 6, height: 6)
                    }
                    if context.closed {
                        Image(systemName: "bolt.slash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.rxWarning)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : (visibleInSplit ? .medium : .regular)))
                        .foregroundStyle(selected || visibleInSplit ? Color.rxInk : Color.rxInkSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160)
                }
                .padding(.leading, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if selected || visibleInSplit {
                Button {
                    TerminalSessionActions.close(context)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.rxInkSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
            }
        }
        .padding(.trailing, selected || visibleInSplit ? 4 : 12)
        .frame(height: inSplitGroup ? 28 : 32)
        .background {
            if selected {
                Capsule().fill(inSplitGroup ? Color.rxAccent.opacity(0.22) : Color.primary.opacity(0.14))
            } else if visibleInSplit {
                Capsule().fill(Color.primary.opacity(0.08))
            }
        }
        .contentShape(.contextMenuPreview, Capsule())
        .contextMenu {
            if let onSplitRight {
                Button(action: onSplitRight) {
                    Label("Split Right with Current Tab", systemImage: "rectangle.split.2x1")
                }
            }
            if let onSplitDown {
                Button(action: onSplitDown) {
                    Label("Split Down with Current Tab", systemImage: "rectangle.split.1x2")
                }
            }
            if let onUngroup {
                Button(action: onUngroup) {
                    Label("Remove from Split Group", systemImage: "rectangle.on.rectangle.slash")
                }
            }
            if context.closed {
                Button { context.reconnect() } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) { TerminalSessionActions.close(context) } label: {
                Label("Close Session", systemImage: "xmark")
            }
        }
    }
}

// MARK: - Snippets

/// The saved snippets: Insert types one into the terminal in front, Run
/// sends it with a return. Beside the terminal on iPad, a sheet on iPhone.
struct TerminalSnippetPanel: View {
    @ObservedObject var context: TerminalContext
    var inSheet = false
    let onClose: () -> Void

    @ObservedObject var store = CatusshStore.shared
    @State private var filter = ""

    private var snippets: [RDSnippet] {
        store.snippetGroup.snippets(matching: filter)
    }

    var body: some View {
        if inSheet {
            list
                .searchable(text: $filter, prompt: "Filter snippets")
                .navigationTitle("Snippets")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onClose)
                    }
                }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Snippets")
                        .font(.headline)
                        .foregroundStyle(.rxInk)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.rxInkSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Snippets")
                }
                .padding(.horizontal, RX.Space.s3)
                .frame(height: 40)
                Hairline()
                TextField("Filter snippets", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .padding(RX.Space.s2)
                Hairline()
                list
            }
            .rxCardChrome()
        }
    }

    @ViewBuilder private var list: some View {
        if snippets.isEmpty {
            VStack(spacing: RX.Space.s2) {
                Text(store.snippetGroup.snippets.isEmpty ? "No snippets saved" : "No matches")
                    .font(.footnote)
                    .foregroundStyle(.rxInkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: RX.Space.s2) {
                    ForEach(snippets) { snippet in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(snippet.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.rxInk)
                                    .lineLimit(1)
                                Spacer()
                                Button("Insert") {
                                    context.insertBuffer(snippet.code)
                                    if inSheet { onClose() }
                                }
                                .buttonStyle(.rx(size: .small))
                                .disabled(context.closed)
                                Button("Run") {
                                    let code = snippet.code.hasSuffix("\n") ? snippet.code : snippet.code + "\n"
                                    context.insertBuffer(code)
                                    if inSheet { onClose() }
                                }
                                .buttonStyle(.rx(.primary, size: .small))
                                .disabled(context.closed)
                            }
                            Text(snippet.code.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.rxCode)
                                .foregroundStyle(.rxInkSecondary)
                                .lineLimit(2)
                        }
                        .padding(RX.Space.s2)
                        .background(
                            RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                }
                .padding(RX.Space.s2)
            }
        }
    }
}
