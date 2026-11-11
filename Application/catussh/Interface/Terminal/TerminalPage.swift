//
//  TerminalPage.swift
//  catussh (macOS)
//

import CatusshDesign
import CatusshModule
import CatusshTerminal
import MachineStatusView
import SwiftUI
import UniformTypeIdentifiers

struct TerminalPage: View {
    @ObservedObject var context: TerminalManager.Context
    @ObservedObject var terminals = TerminalManager.shared
    @EnvironmentObject var store: CatusshStore

    @State private var draggedTabID: TerminalManager.Context.ID?
    @State private var activeSnapZone: TerminalSnapZone?
    @State private var surfaceGeoSize: CGSize = .init(width: 800, height: 500)
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var selectedMatchIndex = 0
    @State private var showSnippetDrawer = false
    @Environment(\.isActivePage) private var isActive

    private var currentSplitGroup: TerminalManager.SplitGroup? {
        terminals.splitGroup(containing: context.id)
    }

    private var visiblePanes: [TerminalManager.Context] { visiblePanes(for: context) }

    private func visiblePanes(for focused: TerminalManager.Context) -> [TerminalManager.Context] {
        terminals.visiblePanes(for: focused)
    }

    /// The tab the router shows now. `onChange` actions can run with the
    /// previous body's `context`, which would hide the tab just opened.
    private var routedContext: TerminalManager.Context {
        if case let .terminal(id) = AppRouter.shared.route,
           let routed = terminals.sessionContexts.first(where: { $0.id == id })
        {
            return routed
        }
        return context
    }

    private var splitOrientation: TerminalManager.SplitOrientation {
        currentSplitGroup?.orientation ?? .horizontal
    }

    private var searchMatches: [(lineNumber: Int, line: String)] {
        guard showSearch else { return [] }
        return context.termInterface.searchTranscript(searchQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            if context.tabSiblings.count > 1 {
                HStack(spacing: RX.Space.s2) {
                    SessionTabs(current: context, draggedTabID: $draggedTabID)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, RX.Space.s6)
                .padding(.bottom, RX.Space.s2)
            }
            HStack(spacing: RX.Space.s3) {
                VStack(spacing: 0) {
                    if context.closed, visiblePanes.count == 1 {
                        disconnectedBanner(for: context)
                    }
                    if showSearch {
                        searchBar
                    }
                    GeometryReader { geo in
                        ZStack {
                            splitSurfaceContainer
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if let zone = activeSnapZone {
                                snapPreviewOverlay(for: zone, in: geo.size)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onAppear { surfaceGeoSize = geo.size }
                        .onChange(of: geo.size) { surfaceGeoSize = $0 }
                        .onDrop(
                            of: [UTType.text],
                            delegate: TerminalCanvasSnapDropDelegate(
                                containerSize: surfaceGeoSize,
                                draggedTabID: $draggedTabID,
                                activeSnapZone: $activeSnapZone,
                                onPerformSnap: { droppedID, zone in
                                    applySnapDrop(droppedID: droppedID, zone: zone)
                                }
                            )
                        )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                        .strokeBorder(Color.rxHairline, lineWidth: 1)
                )

                if showSnippetDrawer {
                    TerminalSnippetDrawer(context: context) {
                        withAnimation(.rxQuick) { showSnippetDrawer = false }
                    }
                    .frame(width: 260)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, RX.Space.s6)
            TerminalStatusBar(context: context)
                .padding(.horizontal, RX.Space.s6)
        }
        .padding(.top, RX.Space.s3)
        .pageChrome()
        .pageToolbar(
            primary: context.closed
                ? ToolbarAction("Reconnect", systemImage: "arrow.clockwise", primary: true) { context.reconnect() }
                : nil,
            trailingMetrics: .controlGroup
        ) {
            ToolbarAction("New Terminal Tab", systemImage: "plus") {
                openAnotherTab()
            }
            ToolbarAction("Split Right (⌘D)", systemImage: "rectangle.split.2x1") {
                splitWithNewOrExisting(orientation: .horizontal)
            }
            ToolbarAction("Split Down (⌘⇧D)", systemImage: "rectangle.split.1x2") {
                splitWithNewOrExisting(orientation: .vertical)
            }
            ToolbarAction("Find in Terminal (⌘F)", systemImage: "magnifyingglass") {
                withAnimation(.rxQuick) { showSearch.toggle() }
            }
            ToolbarAction("Snippets", systemImage: "chevron.left.forwardslash.chevron.right") {
                withAnimation(.rxQuick) { showSnippetDrawer.toggle() }
            }
        } trailing: {
            ToolbarAction("Smaller Text", systemImage: "textformat.size.smaller", isEnabled: store.terminalFontSize > 4) {
                store.terminalFontSize -= 1
            }
            .keyboardShortcut("-", modifiers: .command)
            ToolbarAction("Larger Text", systemImage: "textformat.size.larger", isEnabled: store.terminalFontSize < 30) {
                store.terminalFontSize += 1
            }
            .keyboardShortcut("+", modifiers: .command)
            ToolbarAction("Close Tab", systemImage: "xmark") {
                TerminalSessionActions.close(context)
            }
        }
        .background {
            if isActive {
                Group {
                    Button("Find in Terminal") {
                        withAnimation(.rxQuick) { showSearch.toggle() }
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    Button("Split Right") {
                        splitWithNewOrExisting(orientation: .horizontal)
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    Button("Split Down") {
                        splitWithNewOrExisting(orientation: .vertical)
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        .serverToolSwitcher(
            machine: context.remoteType == .machine && context.machine.isNotPlaceholder() ? context.machine.id : nil,
            current: .terminal
        )
        .onAppear {
            syncActivePanes()
        }
        .onChange(of: context.id) { _ in
            syncActivePanes()
        }
        .onChange(of: terminals.splitGroups) { _ in
            syncActivePanes()
        }
        .onChange(of: isActive) { _ in
            syncActivePanes()
        }
    }

    private func syncActivePanes() {
        let focused = routedContext
        let panes = visiblePanes(for: focused)
        let visibleIDs = Set(panes.map(\.id))
        for session in terminals.sessionContexts where !visibleIDs.contains(session.id) {
            session.termInterface.setActive(false, focus: false)
        }
        guard isActive else {
            for pane in panes { pane.termInterface.setActive(false, focus: false) }
            return
        }
        for pane in panes where pane.id != focused.id {
            pane.termInterface.setActive(true, focus: false)
        }
        // Activate the focused pane with keyboard firstResponder.
        focused.termInterface.setActive(true, focus: true)
    }

    private func openAnotherTab() {
        switch context.remoteType {
        case .machine:
            AppRouter.shared.openTerminal(machine: context.machine.id, another: true)
        case .command:
            if let command = context.command {
                AppRouter.shared.openTerminal(command: command)
            }
        case .local:
            AppRouter.shared.openLocalTerminal(another: true)
        }
    }

    private func splitWithNewOrExisting(orientation: TerminalManager.SplitOrientation) {
        let currentMemberIDs = Set(currentSplitGroup?.memberIDs ?? [context.id])
        // If there is already another ungrouped tab for this server/local shell, group with it first.
        if let ungroupedSibling = context.tabSiblings.first(where: {
            !currentMemberIDs.contains($0.id) && terminals.splitGroup(containing: $0.id) == nil
        }) {
            withAnimation(.rxQuick) {
                terminals.groupSessions(anchorID: context.id, newID: ungroupedSibling.id, orientation: orientation)
                AppRouter.shared.route = .terminal(ungroupedSibling.id)
            }
            return
        }

        // Otherwise create a new tab and immediately join it into the current split group.
        switch context.remoteType {
        case .machine:
            let machine = store.machineGroup[context.machine.id]
            guard machine.isNotPlaceholder() else { return }
            if machine.isUURemoteDevice {
                let anchorID = context.id
                SheetPresenter.present { dismiss in
                    UURemoteSessionPickerSheet(machine: machine) { choice in
                        dismiss()
                        switch choice {
                        case .new:
                            TerminalManager.shared.createSession(withMachineObject: machine, force: true, resuming: nil) { created in
                                withAnimation(.rxQuick) {
                                    TerminalManager.shared.groupSessions(anchorID: anchorID, newID: created.id, orientation: orientation)
                                    AppRouter.shared.route = .terminal(created.id)
                                }
                            }
                        case let .resume(sessionID):
                            TerminalManager.shared.createSession(withMachineObject: machine, force: true, resuming: sessionID) { created in
                                withAnimation(.rxQuick) {
                                    TerminalManager.shared.groupSessions(anchorID: anchorID, newID: created.id, orientation: orientation)
                                    AppRouter.shared.route = .terminal(created.id)
                                }
                            }
                        case nil:
                            break
                        }
                    }
                }
            } else {
                let anchorID = context.id
                TerminalManager.shared.createSession(withMachineObject: machine, force: true) { created in
                    withAnimation(.rxQuick) {
                        TerminalManager.shared.groupSessions(anchorID: anchorID, newID: created.id, orientation: orientation)
                        AppRouter.shared.route = .terminal(created.id)
                    }
                }
            }
        case .command:
            if let command = context.command {
                let anchorID = context.id
                let created = TerminalManager.shared.createSession(withCommand: command)
                withAnimation(.rxQuick) {
                    TerminalManager.shared.groupSessions(anchorID: anchorID, newID: created.id, orientation: orientation)
                    AppRouter.shared.route = .terminal(created.id)
                }
            }
        case .local:
            let anchorID = context.id
            let created = TerminalManager.shared.createLocalSession()
            withAnimation(.rxQuick) {
                TerminalManager.shared.groupSessions(anchorID: anchorID, newID: created.id, orientation: orientation)
                AppRouter.shared.route = .terminal(created.id)
            }
        }
    }

    private func applySnapDrop(droppedID: TerminalManager.Context.ID, zone: TerminalSnapZone) {
        withAnimation(.rxQuick) {
            if let shown = terminals.applySnap(droppedID: droppedID, onto: context, zone: zone) {
                AppRouter.shared.route = .terminal(shown)
            }
        }
    }

    @ViewBuilder private func snapPreviewOverlay(for zone: TerminalSnapZone, in size: CGSize) -> some View {
        let rect = zone.previewRect(in: size)
        ZStack {
            RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                .fill(Color.rxAccent.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                        .strokeBorder(Color.rxAccent.opacity(0.85), lineWidth: 2)
                )
            Label(zone.title, systemImage: zone.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.rxAccent.opacity(0.9)))
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .animation(.rxQuick, value: zone)
    }

    @ViewBuilder private var splitSurfaceContainer: some View {
        let panes = visiblePanes
        if panes.count == 1, let single = panes.first {
            paneSurface(for: single, showHeader: false, totalPanes: 1, index: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if splitOrientation == .horizontal {
            HSplitView {
                ForEach(Array(panes.enumerated()), id: \.element.id) { idx, pane in
                    paneSurface(for: pane, showHeader: true, totalPanes: panes.count, index: idx)
                        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            VSplitView {
                ForEach(Array(panes.enumerated()), id: \.element.id) { idx, pane in
                    paneSurface(for: pane, showHeader: true, totalPanes: panes.count, index: idx)
                        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder private func paneSurface(for pane: TerminalManager.Context, showHeader: Bool, totalPanes: Int, index: Int) -> some View {
        let isFocused = pane.id == context.id
        VStack(spacing: 0) {
            if showHeader {
                HStack(spacing: RX.Space.s2) {
                    Circle()
                        .fill(isFocused ? Color.rxAccent : Color.rxInkTertiary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text("Pane \(index + 1) · \(pane.navigationSubtitle.isEmpty ? pane.displayName : pane.navigationSubtitle)")
                        .font(.system(size: 11, weight: isFocused ? .semibold : .medium))
                        .foregroundStyle(isFocused ? Color.rxInk : Color.rxInkSecondary)
                        .lineLimit(1)
                    Spacer()
                    if pane.closed {
                        Button("Reconnect") { pane.reconnect() }
                            .buttonStyle(.rx(size: .small))
                    }
                    if index == totalPanes - 1 {
                        Button {
                            let next: TerminalManager.SplitOrientation = splitOrientation == .horizontal ? .vertical : .horizontal
                            terminals.setSplitOrientation(for: pane.id, orientation: next)
                        } label: {
                            Image(systemName: splitOrientation == .horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.rxInkSecondary)
                        .help("Switch split orientation")
                    }
                    Button {
                        withAnimation(.rxQuick) {
                            terminals.ungroupSession(pane.id)
                            if isFocused, let remaining = visiblePanes.first(where: { $0.id != pane.id }) {
                                AppRouter.shared.route = .terminal(remaining.id)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.rxInkSecondary)
                    .help("Detach from split group (keep tab open)")
                    Button {
                        TerminalSessionActions.close(pane)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.rxInkSecondary)
                    .help("Close this terminal pane")
                }
                .padding(.horizontal, RX.Space.s3)
                .frame(height: 26)
                .background(isFocused ? Color.rxAccent.opacity(0.10) : Color.rxSurface)
                .contentShape(Rectangle())
                .onTapGesture {
                    AppRouter.shared.route = .terminal(pane.id)
                }
                Hairline()
            }
            if pane.closed, showHeader {
                disconnectedBanner(for: pane)
            }
            // onAppear inside the id: it must run again for each tab shown here.
            pane.termInterface
                .onAppear {
                    pane.termInterface.setTerminalFontSize(with: store.terminalFontSize, preferConfigured: true)
                    pane.termInterface.setActive(true, focus: isFocused)
                }
                .id(pane.id)
                .onChange(of: store.terminalFontSize) { newValue in
                    pane.termInterface.setTerminalFontSize(with: newValue)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    if AppRouter.shared.route != .terminal(pane.id) {
                        AppRouter.shared.route = .terminal(pane.id)
                    }
                })
        }
        .overlay(
            Rectangle()
                .strokeBorder(showHeader && isFocused ? Color.rxAccent.opacity(0.45) : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var searchBar: some View {
        let matches = searchMatches
        let safeIndex = matches.isEmpty ? 0 : min(selectedMatchIndex, matches.count - 1)
        return VStack(spacing: 0) {
            HStack(spacing: RX.Space.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.rxInkSecondary)
                TextField("Find in terminal output…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.rxBody)
                    .onChange(of: searchQuery) { _ in selectedMatchIndex = max(0, searchMatches.count - 1) }
                if !searchQuery.isEmpty {
                    Text(matches.isEmpty ? "0 matches" : "\(safeIndex + 1) of \(matches.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.rxInkSecondary)
                    Button {
                        guard !matches.isEmpty else { return }
                        selectedMatchIndex = (safeIndex - 1 + matches.count) % matches.count
                    } label: {
                        Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(matches.isEmpty)
                    Button {
                        guard !matches.isEmpty else { return }
                        selectedMatchIndex = (safeIndex + 1) % matches.count
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(matches.isEmpty)
                }
                Button {
                    showSearch = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.rxInkSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, RX.Space.s3)
            .frame(height: 34)
            .background(Color.rxSurface)
            if !matches.isEmpty {
                Hairline()
                HStack(spacing: RX.Space.s2) {
                    Text("Line \(matches[safeIndex].lineNumber)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.rxAccent)
                    Text(matches[safeIndex].line)
                        .font(.rxCode)
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy Line") {
                        UIBridge.sendPasteboard(str: matches[safeIndex].line)
                    }
                    .buttonStyle(.rx(size: .small))
                }
                .padding(.horizontal, RX.Space.s3)
                .frame(height: 28)
                .background(Color.rxSurface.opacity(0.92))
            }
            Hairline()
        }
    }

    private func disconnectedBanner(for target: TerminalManager.Context) -> some View {
        HStack(spacing: RX.Space.s2) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.rxWarning)
            Text("Connection closed")
                .foregroundStyle(.rxInk)
            Spacer()
            Button("Reconnect") {
                target.reconnect()
            }
            .buttonStyle(.rx(.primary, size: .small))
        }
        .font(.rxBody)
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 36)
        .background(Color.rxSurface)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

struct SessionTabs: View {
    @ObservedObject var current: TerminalManager.Context
    @Binding var draggedTabID: TerminalManager.Context.ID?
    @ObservedObject var terminals = TerminalManager.shared

    private var siblings: [TerminalManager.Context] { current.tabSiblings }

    /// Clusters adjacent tabs that belong to the same `SplitGroup` into one
    /// visual pill container so it's immediately clear which tabs are split together.
    private var clusters: [TerminalManager.TabCluster] {
        terminals.tabClusters(for: current)
    }

    var body: some View {
        HStack(spacing: RX.Space.s1) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        let totalCount = siblings.count
                        ForEach(clusters) { cluster in
                            if let group = cluster.group {
                                groupedClusterView(group: group, items: cluster.items, totalCount: totalCount)
                            } else if let single = cluster.items.first {
                                tabItemView(index: single.index, context: single.context, totalCount: totalCount, inSplitGroup: false)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { reader.scrollTo(current.id) }
                .onChange(of: current.id) { id in withAnimation(.rxQuick) { reader.scrollTo(id) } }
                .onChange(of: siblings.count) { _ in withAnimation(.rxQuick) { reader.scrollTo(current.id) } }
            }
            Button {
                switch current.remoteType {
                case .machine:
                    AppRouter.shared.openTerminal(machine: current.machine.id, another: true)
                case .command:
                    if let command = current.command {
                        AppRouter.shared.openTerminal(command: command)
                    }
                case .local:
                    AppRouter.shared.openLocalTerminal(another: true)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.rxInkSecondary)
            .help("New Terminal (⌘T)")
            .accessibilityLabel("New Terminal")
        }
    }

    @ViewBuilder
    private func groupedClusterView(
        group: TerminalManager.SplitGroup,
        items: [(index: Int, context: TerminalManager.Context)],
        totalCount: Int
    ) -> some View {
        let isActiveGroup = items.contains { $0.context.id == current.id }
        HStack(spacing: 2) {
            // Split group badge: shows orientation icon + pane count, click to toggle H/V, context menu to ungroup
            Button {
                let next: TerminalManager.SplitOrientation = group.orientation == .horizontal ? .vertical : .horizontal
                if let firstID = items.first?.context.id {
                    terminals.setSplitOrientation(for: firstID, orientation: next)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: group.orientation == .horizontal ? "rectangle.split.2x1.fill" : "rectangle.split.1x2.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(items.count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                }
                .foregroundStyle(isActiveGroup ? Color.rxAccent : Color.rxInkSecondary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    Capsule()
                        .fill(isActiveGroup ? Color.rxAccent.opacity(0.18) : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .help("Split group (\(items.count) panes) · Click to switch horizontal/vertical")
            .padding(.leading, 3)

            ForEach(items, id: \.context.id) { item in
                tabItemView(index: item.index, context: item.context, totalCount: totalCount, inSplitGroup: true)
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
    private func tabItemView(index: Int, context: TerminalManager.Context, totalCount: Int, inSplitGroup: Bool) -> some View {
        let isVisibleInSplit = terminals.splitGroup(containing: current.id)?.memberIDs.contains(context.id) == true
        SessionTab(
            context: context,
            selected: context.id == current.id,
            visibleInSplit: isVisibleInSplit && context.id != current.id,
            inSplitGroup: inSplitGroup,
            number: totalCount > 1 ? index + 1 : nil,
            shortcut: totalCount > 1 ? Self.shortcut(index: index, count: totalCount) : nil,
            onSplitRight: context.id == current.id ? nil : {
                withAnimation(.rxQuick) {
                    terminals.groupSessions(anchorID: current.id, newID: context.id, orientation: .horizontal)
                }
            },
            onSplitDown: context.id == current.id ? nil : {
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
            delegate: SessionTabDropDelegate(
                targetID: context.id,
                draggedID: $draggedTabID
            )
        )
    }
}

private struct TerminalCanvasSnapDropDelegate: DropDelegate {
    let containerSize: CGSize
    @Binding var draggedTabID: TerminalManager.Context.ID?
    @Binding var activeSnapZone: TerminalSnapZone?
    let onPerformSnap: (TerminalManager.Context.ID, TerminalSnapZone) -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        draggedTabID != nil
    }

    func dropEntered(info: DropInfo) {
        updateZone(for: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateZone(for: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        activeSnapZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = zone(for: info.location)
        activeSnapZone = nil
        if let id = draggedTabID {
            draggedTabID = nil
            onPerformSnap(id, zone)
            return true
        }
        return false
    }

    private func updateZone(for pt: CGPoint) {
        guard draggedTabID != nil else {
            activeSnapZone = nil
            return
        }
        let next = zone(for: pt)
        if activeSnapZone != next {
            activeSnapZone = next
        }
    }

    private func zone(for pt: CGPoint) -> TerminalSnapZone {
        TerminalSnapZone.zone(at: pt, in: containerSize)
    }
}

private struct SessionTabDropDelegate: DropDelegate {
    let targetID: TerminalManager.Context.ID
    @Binding var draggedID: TerminalManager.Context.ID?

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

private struct TerminalSnippetDrawer: View {
    @ObservedObject var context: TerminalManager.Context
    let onClose: () -> Void

    @EnvironmentObject var store: CatusshStore
    @State private var filter = ""

    private var snippets: [RDSnippet] {
        store.snippetGroup.snippets(matching: filter)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Snippets")
                    .font(.rxBodyStrong)
                    .foregroundStyle(.rxInk)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.rxInkSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, RX.Space.s3)
            .frame(height: 36)

            Hairline()

            RXSearchField("Filter snippets", text: $filter, width: nil)
                .padding(RX.Space.s2)

            Hairline()

            if snippets.isEmpty {
                VStack(spacing: RX.Space.s2) {
                    Text(store.snippetGroup.snippets.isEmpty ? "No snippets saved" : "No matches")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                    if store.snippetGroup.snippets.isEmpty {
                        Button("Open Snippets") {
                            AppRouter.shared.route = .snippets
                        }
                        .buttonStyle(.rx(size: .small))
                    }
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
                                        .font(.rxBodyStrong)
                                        .foregroundStyle(.rxInk)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Insert") {
                                        context.insertBuffer(snippet.code)
                                    }
                                    .buttonStyle(.rx(size: .small))
                                    .disabled(context.closed)
                                    Button("Run") {
                                        let code = snippet.code.hasSuffix("\n") ? snippet.code : snippet.code + "\n"
                                        context.insertBuffer(code)
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
        .rxCardChrome()
    }
}

extension SessionTabs {
    static func shortcut(index: Int, count: Int) -> String? {
        if index < 8 { return "⌘\(index + 1)" }
        return index == count - 1 ? "⌘9" : nil
    }
}

private struct SessionTab: View {
    private static let closeGlyphSize: CGFloat = 9

    @ObservedObject var context: TerminalManager.Context
    let selected: Bool
    var visibleInSplit = false
    var inSplitGroup = false
    let number: Int?
    var shortcut: String?
    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?
    var onUngroup: (() -> Void)?

    private var title: String {
        if !context.navigationSubtitle.isEmpty { return context.navigationSubtitle }
        if let number { return "Terminal \(number)" }
        return context.remoteType == .machine ? "Terminal" : context.displayName
    }
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                AppRouter.shared.route = .terminal(context.id)
            } label: {
                HStack(spacing: 6) {
                    if inSplitGroup {
                        Circle()
                            .fill(selected ? Color.rxAccent : (visibleInSplit ? Color.rxAccent.opacity(0.45) : Color.rxInkTertiary))
                            .frame(width: 6, height: 6)
                    }
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : (visibleInSplit ? .medium : .regular)))
                        .foregroundStyle(selected || visibleInSplit ? Color.rxInk : Color.rxInkSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 160)
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.rxInkTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 10)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button {
                TerminalSessionActions.close(context)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Self.closeGlyphSize, weight: .bold))
                    .foregroundStyle(.rxInkSecondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .opacity(selected || visibleInSplit || hovered ? 1 : 0)
            .accessibilityLabel("Close \(title)")
        }
        .frame(height: inSplitGroup ? RX.controlHeight - 4 : RX.controlHeight)
        .background {
            if selected {
                Capsule().fill(inSplitGroup ? Color.rxAccent.opacity(0.22) : Color.primary.opacity(0.14))
            } else if visibleInSplit {
                Capsule().fill(Color.primary.opacity(0.08))
            } else if hovered {
                Capsule().fill(Color.primary.opacity(0.06))
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            if let onSplitRight {
                Button("Split Right with Current Tab", action: onSplitRight)
            }
            if let onSplitDown {
                Button("Split Down with Current Tab", action: onSplitDown)
            }
            if let onUngroup {
                Button("Remove from Split Group", action: onUngroup)
            }
            if onSplitRight != nil || onSplitDown != nil || onUngroup != nil {
                Divider()
            }
            if context.closed { Button("Reconnect") { context.reconnect() } }
            Button("Close Session") { TerminalSessionActions.close(context) }
        }
    }
}

private struct TerminalStatusBar: View {
    @ObservedObject var context: TerminalManager.Context
    @ObservedObject var monitors = MonitorCenter.shared
    @EnvironmentObject var store: CatusshStore

    var body: some View {
        HStack(spacing: RX.Space.s4) {
            RedactableText(endpoint, redacted: store.machineRedacted != .none)
                .font(.rxCode)
            Spacer(minLength: RX.Space.s2)
            if let session = monitors.session(for: context.machine.id) {
                LiveFigures(session: session)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.rxInkSecondary)
        .padding(.horizontal, RX.Space.s1)
        .frame(height: 32)
    }

    var endpoint: String { context.endpointDescription }

    private struct LiveFigures: View {
        @ObservedObject var session: MonitorSession
        var body: some View {
            if session.status.hasData {
                Text("CPU \(RXFormat.percent(Double(session.status.processor.summary.sumUsed)))%")
                Text("Mem \(RXFormat.percent(session.status.memoryUsedPercent))%")
                Text("↓ \(RXFormat.rateString(Double(session.status.totalReceivePerSecond))) ↑ \(RXFormat.rateString(Double(session.status.totalTransmitPerSecond)))")
            }
        }
    }
}

enum TerminalSessionActions {
    @MainActor
    static func closeTab(_ context: TerminalManager.Context) {
        let manager = TerminalManager.shared
        let keepsSession = context.machine.isUURemoteDevice
        let replace = context.tabSiblings.count == 1 && !keepsSession
        let perform = {
            guard manager.sessionContexts.contains(where: { $0.id == context.id }) else { return }
            if replace, let fresh = openReplacement(for: context) {
                AppRouter.shared.route = .terminal(fresh.id)
            } else {
                showNeighbour(of: context)
            }
            manager.closeSession(withContextID: context.id)
        }
        if manager.sessionAlive(forContext: context.id), !keepsSession {
            UIBridge.requiresConfirmation(
                message: "Close this terminal tab?",
                informative: replace
                    ? "Its session on \(context.displayName) ends, and a new terminal to the same server opens in its place."
                    : "Its session on \(context.displayName) ends.",
                confirmTitle: "Close Tab",
                destructive: true
            ) { confirmed in
                if confirmed { MainActor.assumeIsolated { perform() } }
            }
        } else {
            perform()
        }
    }

    @MainActor
    private static func openReplacement(for context: TerminalManager.Context) -> TerminalManager.Context? {
        let manager = TerminalManager.shared
        switch context.remoteType {
        case .machine:
            let machine = CatusshStore.shared.machineGroup[context.machine.id]
            guard machine.isNotPlaceholder() else { return nil }
            var created: TerminalManager.Context?
            manager.createSession(withMachineObject: machine, force: true) { created = $0 }
            return created
        case .command:
            return context.command.map { manager.createSession(withCommand: $0) }
        case .local:
            return manager.createLocalSession()
        }
    }

    @MainActor
    static func close(_ context: TerminalManager.Context) {
        let manager = TerminalManager.shared
        let perform = {
            showNeighbour(of: context)
            manager.closeSession(withContextID: context.id)
        }
        if manager.sessionAlive(forContext: context.id), !context.machine.isUURemoteDevice {
            UIBridge.requiresConfirmation(
                message: "Close this terminal tab?",
                informative: "Its session on \(context.displayName) ends.",
                confirmTitle: "Close Tab",
                destructive: true
            ) { confirmed in
                if confirmed { MainActor.assumeIsolated { perform() } }
            }
        } else {
            perform()
        }
    }

    @MainActor
    private static func showNeighbour(of context: TerminalManager.Context) {
        guard AppRouter.shared.route == .terminal(context.id) else { return }
        let siblings = context.tabSiblings
        guard let index = siblings.firstIndex(where: { $0.id == context.id }), siblings.count > 1 else {
            if context.remoteType == .machine,
               let desktop = RemoteDesktopManager.shared.sessions.first(where: { $0.machine.id == context.machine.id })
            {
                AppRouter.shared.route = .desktop(desktop.id)
            }
            return
        }
        let neighbour = index + 1 < siblings.count ? siblings[index + 1] : siblings[index - 1]
        AppRouter.shared.route = .terminal(neighbour.id)
    }
}
