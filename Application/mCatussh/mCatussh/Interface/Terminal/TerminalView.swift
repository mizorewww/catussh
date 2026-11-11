//
//  TerminalView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//
//  A server's terminals, as on the Mac: tabs (grouped into pills when split
//  together, dragged to reorder), find in scrollback, snippets, and a status
//  line. Where the screen is wide enough (iPad) split tabs show side by side
//  or stacked, and a tab dragged onto the terminal snaps to the side it is
//  dropped on; on a narrow screen only the tab in front shows.
//

import CatusshModule
import CatusshTerminal
import MachineStatusView
import SwiftUI
import UniformTypeIdentifiers

struct TerminalView: View {
    @ObservedObject var context: TerminalContext

    @State var interfaceToken = UUID()

    @ObservedObject var store = CatusshStore.shared
    @ObservedObject var terminals = TerminalManager.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.inServerWorkspace) private var inServerWorkspace

    /// The tab in front; `context` until another tab is chosen.
    @State private var focusedID: TerminalContext.ID?
    /// The tabs of this screen as last seen, to pick a neighbour when the
    /// tab in front closes.
    @State private var lastSiblingIDs: [TerminalContext.ID] = []
    @State private var draggedTabID: TerminalContext.ID?
    @State private var activeSnapZone: TerminalSnapZone?
    @State private var canvasSize: CGSize = .init(width: 400, height: 400)
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var selectedMatchIndex = 0
    @State private var showSnippets = false

    /// Below this width only the tab in front shows, and splits are not offered.
    private static let splitMinimumWidth: CGFloat = 600

    private var focused: TerminalContext {
        if let focusedID, let found = terminals.sessionContexts.first(where: { $0.id == focusedID }) {
            return found
        }
        return context
    }

    private var siblings: [TerminalContext] { focused.tabSiblings }

    private var canSplit: Bool { canvasSize.width >= Self.splitMinimumWidth }

    private var panes: [TerminalContext] {
        canSplit ? terminals.visiblePanes(for: focused) : [focused]
    }

    private var splitOrientation: TerminalManager.SplitOrientation {
        terminals.splitGroup(containing: focused.id)?.orientation ?? .horizontal
    }

    private var searchMatches: [(lineNumber: Int, line: String)] {
        guard showSearch else { return [] }
        return focused.termInterface.searchTranscript(searchQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            if siblings.count > 1 {
                TerminalTabStrip(
                    current: focused,
                    draggedTabID: $draggedTabID,
                    canSplit: canSplit,
                    select: { focus($0) },
                    newTab: { openAnotherTab() }
                )
                .padding(.horizontal, RX.Space.s3)
                .padding(.vertical, RX.Space.s1)
            }
            HStack(spacing: RX.Space.s3) {
                VStack(spacing: 0) {
                    if focused.closed, panes.count == 1 {
                        disconnectedBanner(for: focused)
                    }
                    if showSearch {
                        searchBar
                    }
                    canvas
                }
                .clipShape(RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous))
                if showSnippets, canSplit {
                    TerminalSnippetPanel(context: focused) {
                        withAnimation(.rxQuick) { showSnippets = false }
                    }
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, canSplit ? RX.Space.s3 : 2)
            TerminalStatusLine(context: focused)
                .padding(.horizontal, RX.Space.s3)
        }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle(focused.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .background { keyboardShortcuts }
        .sheet(isPresented: Binding(get: { showSnippets && !canSplit }, set: { showSnippets = $0 })) {
            NavigationStack {
                TerminalSnippetPanel(context: focused, inSheet: true) {
                    showSnippets = false
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            if focusedID == nil { focusedID = context.id }
            lastSiblingIDs = siblings.map(\.id)
            claimPanes()
        }
        .onDisappear {
            TerminalFocus.shared.remove(screen: interfaceToken)
        }
        .onChange(of: focusedID) { _ in claimPanes() }
        .onChange(of: terminals.splitGroups) { _ in claimPanes() }
        .onChange(of: canSplit) { _ in claimPanes() }
        .onChange(of: terminals.sessionContexts.map(\.id)) { ids in
            sessionsChanged(ids)
        }
        .onReceive(TerminalFocus.shared.requests) { id in
            guard id != focusedID, siblings.contains(where: { $0.id == id }) else { return }
            focus(id)
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                splitSurfaces
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let zone = activeSnapZone {
                    snapPreview(for: zone, in: geo.size)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { canvasSize = $0 }
            .onDrop(
                of: [UTType.text],
                delegate: TerminalSnapDropDelegate(
                    containerSize: canvasSize,
                    enabled: canSplit,
                    draggedTabID: $draggedTabID,
                    activeSnapZone: $activeSnapZone
                ) { droppedID, zone in
                    withAnimation(.rxQuick) {
                        if let shown = terminals.applySnap(droppedID: droppedID, onto: focused, zone: zone) {
                            focus(shown)
                        }
                    }
                }
            )
        }
    }

    @ViewBuilder private var splitSurfaces: some View {
        let panes = panes
        if panes.count == 1, let single = panes.first {
            paneSurface(for: single, showHeader: false, totalPanes: 1, index: 0)
        } else if splitOrientation == .horizontal {
            HStack(spacing: 1) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    paneSurface(for: pane, showHeader: true, totalPanes: panes.count, index: index)
                }
            }
            .background(Color.rxHairline)
        } else {
            VStack(spacing: 1) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    paneSurface(for: pane, showHeader: true, totalPanes: panes.count, index: index)
                }
            }
            .background(Color.rxHairline)
        }
    }

    @ViewBuilder private func paneSurface(for pane: TerminalContext, showHeader: Bool, totalPanes: Int, index: Int) -> some View {
        let isFocused = pane.id == focused.id
        VStack(spacing: 0) {
            if showHeader {
                TerminalPaneHeader(
                    pane: pane,
                    index: index,
                    isFocused: isFocused,
                    isLast: index == totalPanes - 1,
                    orientation: splitOrientation,
                    focus: { focus(pane.id) },
                    detach: {
                        withAnimation(.rxQuick) {
                            terminals.ungroupSession(pane.id)
                        }
                    },
                    close: { close(pane) }
                )
                if pane.closed {
                    disconnectedBanner(for: pane)
                }
            }
            TerminalPaneSurface(pane: pane, token: interfaceToken, fontSize: store.terminalFontSize, compact: !canSplit)
                .id(pane.id)
                .simultaneousGesture(TapGesture().onEnded {
                    if focusedID != pane.id { focus(pane.id) }
                })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.rxSurface)
        .overlay(
            Rectangle()
                .strokeBorder(showHeader && isFocused ? Color.rxAccent.opacity(0.45) : Color.clear, lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private func snapPreview(for zone: TerminalSnapZone, in size: CGSize) -> some View {
        let rect = zone.previewRect(in: size)
        return ZStack {
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

    // MARK: - Find

    private var searchBar: some View {
        let matches = searchMatches
        let safeIndex = matches.isEmpty ? 0 : min(selectedMatchIndex, matches.count - 1)
        return VStack(spacing: 0) {
            HStack(spacing: RX.Space.s2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.rxInkSecondary)
                TextField("Find in terminal output…", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .onSubmit { step(1, in: matches) }
                    .onChange(of: searchQuery) { _ in selectedMatchIndex = max(0, searchMatches.count - 1) }
                if !searchQuery.isEmpty {
                    Text(matches.isEmpty ? "0 matches" : "\(safeIndex + 1) of \(matches.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.rxInkSecondary)
                    Button { step(-1, in: matches) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(matches.isEmpty)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .accessibilityLabel("Previous Match")
                    Button { step(1, in: matches) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(matches.isEmpty)
                    .keyboardShortcut("g", modifiers: .command)
                    .accessibilityLabel("Next Match")
                }
                Button {
                    withAnimation(.rxQuick) { showSearch = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.rxInkSecondary)
                }
                .accessibilityLabel("Close Find")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, RX.Space.s3)
            .frame(height: 40)
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
                    Spacer()
                    Button("Copy Line") {
                        UIBridge.sendPasteboard(str: matches[safeIndex].line)
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, RX.Space.s3)
                .frame(height: 32)
                .background(Color.rxSurface.opacity(0.92))
            }
            Hairline()
        }
    }

    private func step(_ delta: Int, in matches: [(lineNumber: Int, line: String)]) {
        guard !matches.isEmpty else { return }
        let safeIndex = min(selectedMatchIndex, matches.count - 1)
        selectedMatchIndex = (safeIndex + delta + matches.count) % matches.count
    }

    private func disconnectedBanner(for target: TerminalContext) -> some View {
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
        .font(.subheadline)
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 40)
        .background(Color.rxSurface)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if focused.closed {
                Button {
                    focused.reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
            }
            Button {
                withAnimation(.rxQuick) { showSearch.toggle() }
            } label: {
                Label("Find in Terminal", systemImage: "magnifyingglass")
            }
            Menu {
                Section {
                    Button { openAnotherTab() } label: {
                        Label("New Terminal Tab", systemImage: "plus")
                    }
                    .disabled(focused.remoteType == .local)
                    if canSplit {
                        Button { split(.horizontal) } label: {
                            Label("Split Right", systemImage: "rectangle.split.2x1")
                        }
                        Button { split(.vertical) } label: {
                            Label("Split Down", systemImage: "rectangle.split.1x2")
                        }
                    }
                }
                Section {
                    Button {
                        withAnimation(.rxQuick) { showSnippets.toggle() }
                    } label: {
                        Label("Snippets", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button { store.terminalFontSize -= 1 } label: {
                        Label("Smaller Text", systemImage: "textformat.size.smaller")
                    }
                    .disabled(store.terminalFontSize <= 4)
                    Button { store.terminalFontSize += 1 } label: {
                        Label("Larger Text", systemImage: "textformat.size.larger")
                    }
                    .disabled(store.terminalFontSize >= 30)
                }
                Section {
                    Button(role: .destructive) { close(focused) } label: {
                        Label("Close Tab", systemImage: "xmark")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    /// iPad hardware keyboard: the Mac's terminal shortcuts.
    private var keyboardShortcuts: some View {
        Group {
            Button("Find in Terminal") { withAnimation(.rxQuick) { showSearch.toggle() } }
                .keyboardShortcut("f", modifiers: .command)
            Button("New Terminal Tab") { openAnotherTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") { close(focused) }
                .keyboardShortcut("w", modifiers: .command)
            Button("Split Right") { split(.horizontal) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { split(.vertical) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Smaller Text") { if store.terminalFontSize > 4 { store.terminalFontSize -= 1 } }
                .keyboardShortcut("-", modifiers: .command)
            Button("Larger Text") { if store.terminalFontSize < 30 { store.terminalFontSize += 1 } }
                .keyboardShortcut("+", modifiers: .command)
            Button("Previous Tab") { cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Tab") { cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            ForEach(1 ... 9, id: \.self) { number in
                Button("Tab \(number)") { selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private func focus(_ id: TerminalContext.ID) {
        focusedID = id
    }

    /// Takes the panes on screen for this view, and tells the terminals that
    /// are not shown to stop drawing.
    private func claimPanes() {
        let shown = panes
        let shownIDs = Set(shown.map(\.id))
        for sibling in siblings where !shownIDs.contains(sibling.id) {
            sibling.termInterface.setActive(false, focus: false)
        }
        for pane in shown {
            pane.interfaceToken = interfaceToken
            pane.termInterface.setActive(true, focus: false)
        }
        TerminalFocus.shared.show(focused.id, on: interfaceToken)
    }

    private func sessionsChanged(_ ids: [TerminalContext.ID]) {
        let alive = Set(ids)
        defer { lastSiblingIDs = siblings.map(\.id).filter(alive.contains) }
        guard let focusedID, !alive.contains(focusedID) else { return }
        // The tab in front closed: show its neighbour, or leave.
        let previous = lastSiblingIDs
        if let index = previous.firstIndex(of: focusedID) {
            let after = previous[(index + 1)...].first(where: alive.contains)
            let before = previous[..<index].last(where: alive.contains)
            if let next = after ?? before {
                self.focusedID = next
                return
            }
        }
        // On a server's page, the page stays for its other tools.
        if !alive.contains(context.id), !inServerWorkspace { dismiss() }
    }

    private func openAnotherTab() {
        TerminalManager.shared.openAnotherTab(like: focused) { created in
            focus(created.id)
        }
    }

    private func split(_ orientation: TerminalManager.SplitOrientation) {
        guard canSplit else { return }
        let anchor = focused
        let members = Set(terminals.splitGroup(containing: anchor.id)?.memberIDs ?? [anchor.id])
        // Another tab of this server not split with anything joins first.
        if let ungrouped = anchor.tabSiblings.first(where: {
            !members.contains($0.id) && terminals.splitGroup(containing: $0.id) == nil
        }) {
            withAnimation(.rxQuick) {
                terminals.groupSessions(anchorID: anchor.id, newID: ungrouped.id, orientation: orientation)
                focus(ungrouped.id)
            }
            return
        }
        TerminalManager.shared.openAnotherTab(like: anchor) { created in
            withAnimation(.rxQuick) {
                TerminalManager.shared.groupSessions(anchorID: anchor.id, newID: created.id, orientation: orientation)
                focus(created.id)
            }
        }
    }

    private func close(_ pane: TerminalContext) {
        TerminalSessionActions.close(pane)
    }

    private func cycleTab(_ delta: Int) {
        let list = siblings
        guard list.count > 1, let index = list.firstIndex(where: { $0.id == focused.id }) else { return }
        focus(list[(index + delta + list.count) % list.count].id)
    }

    /// ⌘1…⌘8 pick that tab, ⌘9 the last, as on the Mac.
    private func selectTab(number: Int) {
        let list = siblings
        guard !list.isEmpty else { return }
        if number == 9 {
            focus(list[list.count - 1].id)
        } else if number - 1 < list.count {
            focus(list[number - 1].id)
        }
    }
}

// MARK: - Pane

/// One terminal surface, shown only by the screen that claimed it last: the
/// same native view cannot be in two places.
private struct TerminalPaneSurface: View {
    @ObservedObject var pane: TerminalContext
    let token: UUID
    let fontSize: Int
    let compact: Bool

    var body: some View {
        if pane.interfaceToken == token {
            pane.termInterface
                .onAppear {
                    pane.termInterface.setTerminalFontSize(with: fontSize, preferConfigured: true)
                    pane.termInterface.setActive(true, focus: false)
                }
                .onChange(of: fontSize) { newValue in
                    pane.termInterface.setTerminalFontSize(with: newValue)
                }
                .padding(compact ? 2 : 6)
        } else {
            EmptyStateView(
                "Terminal moved to another window",
                systemImage: "macwindow",
                message: "This session is open in another window."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Above each pane of a split: which pane, Reconnect, the orientation
/// switch (on the last pane), Detach and Close.
private struct TerminalPaneHeader: View {
    @ObservedObject var pane: TerminalContext
    let index: Int
    let isFocused: Bool
    let isLast: Bool
    let orientation: TerminalManager.SplitOrientation
    let focus: () -> Void
    let detach: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: RX.Space.s3) {
                Circle()
                    .fill(isFocused ? Color.rxAccent : Color.rxInkTertiary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text("Pane \(index + 1) · \(pane.navigationSubtitle.isEmpty ? pane.displayName : pane.navigationSubtitle)")
                    .font(.system(size: 12, weight: isFocused ? .semibold : .medium))
                    .foregroundStyle(isFocused ? Color.rxInk : Color.rxInkSecondary)
                    .lineLimit(1)
                Spacer()
                if isLast {
                    Button {
                        let next: TerminalManager.SplitOrientation = orientation == .horizontal ? .vertical : .horizontal
                        withAnimation(.rxQuick) {
                            TerminalManager.shared.setSplitOrientation(for: pane.id, orientation: next)
                        }
                    } label: {
                        Image(systemName: orientation == .horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1")
                    }
                    .accessibilityLabel("Switch split orientation")
                }
                Button(action: detach) {
                    Image(systemName: "rectangle.on.rectangle.slash")
                }
                .accessibilityLabel("Detach from split group (keep tab open)")
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .accessibilityLabel("Close this terminal pane")
            }
            .font(.system(size: 13))
            .buttonStyle(.plain)
            .foregroundStyle(.rxInkSecondary)
            .padding(.horizontal, RX.Space.s3)
            .frame(height: 32)
            .background(isFocused ? Color.rxAccent.opacity(0.10) : Color.rxSurface)
            .contentShape(Rectangle())
            .onTapGesture(perform: focus)
            Hairline()
        }
    }
}

// MARK: - Status line

/// The endpoint, and the server's live figures when its monitor is open.
private struct TerminalStatusLine: View {
    @ObservedObject var context: TerminalContext
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var store = CatusshStore.shared

    var body: some View {
        HStack(spacing: RX.Space.s4) {
            RedactableText(context.endpointDescription, redacted: store.machineRedacted != .none)
                .font(.rxCode)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: RX.Space.s2)
            if let session = monitors.session(for: context.machine.id) {
                LiveFigures(session: session)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.rxInkSecondary)
        .padding(.horizontal, RX.Space.s1)
        .frame(height: 28)
    }

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

// MARK: - Drop

/// A tab dragged over the terminal: the zone under the finger previews
/// where it lands; dropped, it is split there.
private struct TerminalSnapDropDelegate: DropDelegate {
    let containerSize: CGSize
    let enabled: Bool
    @Binding var draggedTabID: TerminalContext.ID?
    @Binding var activeSnapZone: TerminalSnapZone?
    let onPerformSnap: (TerminalContext.ID, TerminalSnapZone) -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        enabled && draggedTabID != nil
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
        let zone = TerminalSnapZone.zone(at: info.location, in: containerSize)
        activeSnapZone = nil
        guard let id = draggedTabID else { return false }
        draggedTabID = nil
        onPerformSnap(id, zone)
        return true
    }

    private func updateZone(for point: CGPoint) {
        guard enabled, draggedTabID != nil else {
            activeSnapZone = nil
            return
        }
        let next = TerminalSnapZone.zone(at: point, in: containerSize)
        if activeSnapZone != next { activeSnapZone = next }
    }
}
