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

extension Notification.Name {
    static let catusshTerminalSplitRequest = Notification.Name("me.mizorewww.rayon.terminalSplitRequest")
}

enum TerminalSplitAxis: String, CaseIterable {
    case horizontal
    case vertical
}

enum TerminalSnapZone: Equatable {
    case left
    case right
    case top
    case bottom
    case center
}

struct TerminalPage: View {
    @ObservedObject var context: TerminalManager.Context
    @ObservedObject var terminals = TerminalManager.shared
    @EnvironmentObject var store: CatusshStore

    @State private var interfaceToken = UUID()
    @State private var secondaryContextID: TerminalManager.Context.ID?
    @State private var splitAxis: TerminalSplitAxis = .horizontal
    @State private var primaryFirst = true
    @State private var draggedTabID: TerminalManager.Context.ID?
    @State private var activeSnapZone: TerminalSnapZone?
    @State private var surfaceGeoSize: CGSize = .init(width: 800, height: 500)
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var selectedMatchIndex = 0
    @State private var showSnippetDrawer = false
    @Environment(\.isActivePage) private var isActive

    private var secondaryContext: TerminalManager.Context? {
        guard let secondaryContextID, secondaryContextID != context.id else { return nil }
        return context.tabSiblings.first { $0.id == secondaryContextID }
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
                    if context.closed {
                        disconnectedBanner
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
            ToolbarAction(
                secondaryContext == nil ? "Split Right (⌘D)" : "Close Split Pane",
                systemImage: secondaryContext == nil ? "rectangle.split.2x1" : "rectangle"
            ) {
                toggleSplit(axis: .horizontal)
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
                        toggleSplit(axis: .horizontal)
                    }
                    .keyboardShortcut("d", modifiers: .command)
                    Button("Split Down") {
                        toggleSplit(axis: .vertical)
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
            context.interfaceToken = interfaceToken
            context.termInterface.setActive(isActive)
        }
        .onChange(of: isActive) { active in
            context.termInterface.setActive(active)
            secondaryContext?.termInterface.setActive(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .catusshTerminalSplitRequest)) { note in
            guard isActive,
                  let targetID = note.userInfo?["targetID"] as? UUID,
                  let rawAxis = note.userInfo?["axis"] as? String,
                  let axis = TerminalSplitAxis(rawValue: rawAxis),
                  let target = context.tabSiblings.first(where: { $0.id == targetID }),
                  target.id != context.id
            else { return }
            splitAxis = axis
            primaryFirst = true
            target.interfaceToken = target.id
            secondaryContextID = target.id
        }
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

    private func toggleSplit(axis: TerminalSplitAxis) {
        if secondaryContext != nil, splitAxis == axis {
            secondaryContext?.termInterface.setActive(false)
            secondaryContextID = nil
            return
        }
        splitAxis = axis
        if let existing = context.tabSiblings.first(where: { $0.id != context.id }) {
            existing.interfaceToken = existing.id
            secondaryContextID = existing.id
            return
        }
        switch context.remoteType {
        case .machine:
            let machine = store.machineGroup[context.machine.id]
            guard machine.isNotPlaceholder() else { return }
            if machine.isUURemoteDevice {
                SheetPresenter.present { dismiss in
                    UURemoteSessionPickerSheet(machine: machine) { choice in
                        dismiss()
                        switch choice {
                        case .new:
                            TerminalManager.shared.createSession(withMachineObject: machine, force: true, resuming: nil) { created in
                                created.interfaceToken = created.id
                                self.secondaryContextID = created.id
                            }
                        case let .resume(sessionID):
                            TerminalManager.shared.createSession(withMachineObject: machine, force: true, resuming: sessionID) { created in
                                created.interfaceToken = created.id
                                self.secondaryContextID = created.id
                            }
                        case nil:
                            break
                        }
                    }
                }
            } else {
                TerminalManager.shared.createSession(withMachineObject: machine, force: true) { created in
                    created.interfaceToken = created.id
                    secondaryContextID = created.id
                }
            }
        case .command:
            if let command = context.command {
                let created = TerminalManager.shared.createSession(withCommand: command)
                created.interfaceToken = created.id
                secondaryContextID = created.id
            }
        case .local:
            let created = TerminalManager.shared.createLocalSession()
            created.interfaceToken = created.id
            secondaryContextID = created.id
        }
    }

    private func applySnapDrop(droppedID: TerminalManager.Context.ID, zone: TerminalSnapZone) {
        guard let dropped = context.tabSiblings.first(where: { $0.id == droppedID }) else { return }
        switch zone {
        case .center:
            secondaryContext?.termInterface.setActive(false)
            secondaryContextID = nil
            AppRouter.shared.route = .terminal(dropped.id)
        case .right:
            guard dropped.id != context.id else { return }
            splitAxis = .horizontal
            primaryFirst = true
            dropped.interfaceToken = dropped.id
            secondaryContextID = dropped.id
        case .bottom:
            guard dropped.id != context.id else { return }
            splitAxis = .vertical
            primaryFirst = true
            dropped.interfaceToken = dropped.id
            secondaryContextID = dropped.id
        case .left:
            guard dropped.id != context.id else { return }
            splitAxis = .horizontal
            primaryFirst = false
            dropped.interfaceToken = dropped.id
            secondaryContextID = dropped.id
        case .top:
            guard dropped.id != context.id else { return }
            splitAxis = .vertical
            primaryFirst = false
            dropped.interfaceToken = dropped.id
            secondaryContextID = dropped.id
        }
    }

    @ViewBuilder private func snapPreviewOverlay(for zone: TerminalSnapZone, in size: CGSize) -> some View {
        let inset: CGFloat = 8
        let rect: CGRect = {
            switch zone {
            case .left:
                return CGRect(x: inset, y: inset, width: max(80, size.width / 2 - inset * 1.5), height: max(80, size.height - inset * 2))
            case .right:
                return CGRect(x: size.width / 2 + inset * 0.5, y: inset, width: max(80, size.width / 2 - inset * 1.5), height: max(80, size.height - inset * 2))
            case .top:
                return CGRect(x: inset, y: inset, width: max(80, size.width - inset * 2), height: max(80, size.height / 2 - inset * 1.5))
            case .bottom:
                return CGRect(x: inset, y: size.height / 2 + inset * 0.5, width: max(80, size.width - inset * 2), height: max(80, size.height / 2 - inset * 1.5))
            case .center:
                return CGRect(x: inset, y: inset, width: max(80, size.width - inset * 2), height: max(80, size.height - inset * 2))
            }
        }()
        let label: String = {
            switch zone {
            case .left: return "Split Left"
            case .right: return "Split Right"
            case .top: return "Split Top"
            case .bottom: return "Split Bottom"
            case .center: return "Switch Tab"
            }
        }()
        ZStack {
            RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                .fill(Color.rxAccent.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                        .strokeBorder(Color.rxAccent.opacity(0.85), lineWidth: 2)
                )
            Label(label, systemImage: zone == .left || zone == .right ? "rectangle.split.2x1" : (zone == .top || zone == .bottom ? "rectangle.split.1x2" : "macwindow"))
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
        if let secondary = secondaryContext {
            if splitAxis == .horizontal {
                HSplitView {
                    if primaryFirst {
                        surface
                            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                        secondarySurface(for: secondary)
                            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        secondarySurface(for: secondary)
                            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                        surface
                            .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                VSplitView {
                    if primaryFirst {
                        surface
                            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                        secondarySurface(for: secondary)
                            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                    } else {
                        secondarySurface(for: secondary)
                            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                        surface
                            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
                    }
                }
            }
        } else {
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func secondarySurface(for pane: TerminalManager.Context) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: RX.Space.s2) {
                Text(pane.navigationSubtitle.isEmpty ? pane.displayName : pane.navigationSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    splitAxis = splitAxis == .horizontal ? .vertical : .horizontal
                } label: {
                    Image(systemName: splitAxis == .horizontal ? "rectangle.split.1x2" : "rectangle.split.2x1")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.rxInkSecondary)
                .help("Switch split orientation")
                Button {
                    pane.termInterface.setActive(false)
                    secondaryContextID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.rxInkSecondary)
                .help("Unsplit pane")
            }
            .padding(.horizontal, RX.Space.s3)
            .frame(height: 26)
            .background(Color.rxSurface)
            Hairline()
            pane.termInterface
                .onAppear {
                    pane.termInterface.setTerminalFontSize(with: store.terminalFontSize, preferConfigured: true)
                }
                .onChange(of: store.terminalFontSize) { newValue in
                    pane.termInterface.setTerminalFontSize(with: newValue)
                }
        }
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

    @ViewBuilder var surface: some View {
        if context.interfaceToken == interfaceToken {
            context.termInterface
                .onChange(of: store.terminalFontSize) { newValue in
                    context.termInterface.setTerminalFontSize(with: newValue)
                }
                .onAppear {
                    context.termInterface.setTerminalFontSize(with: store.terminalFontSize, preferConfigured: true)
                }
        } else {
            EmptyStateView(
                "Terminal moved to another window",
                systemImage: "macwindow",
                actionTitle: "Bring Back Here"
            ) {
                context.interfaceToken = interfaceToken
            }
            .environment(\.colorScheme, .dark)
            .background(Color.rxTerminalBackground)
        }
    }

    var disconnectedBanner: some View {
        HStack(spacing: RX.Space.s2) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.rxWarning)
            Text("Connection closed")
                .foregroundStyle(.rxInk)
            Spacer()
            Button("Reconnect") {
                context.reconnect()
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

    var body: some View {
        HStack(spacing: RX.Space.s1) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RX.Space.s1) {
                        let siblings = siblings
                        ForEach(Array(siblings.enumerated()), id: \.element.id) { index, context in
                            SessionTab(
                                context: context,
                                selected: context.id == current.id,
                                number: siblings.count > 1 ? index + 1 : nil,
                                shortcut: siblings.count > 1 ? Self.shortcut(index: index, count: siblings.count) : nil,
                                onSplitRight: context.id == current.id ? nil : {
                                    NotificationCenter.default.post(
                                        name: .catusshTerminalSplitRequest,
                                        object: nil,
                                        userInfo: ["targetID": context.id, "axis": TerminalSplitAxis.horizontal.rawValue]
                                    )
                                },
                                onSplitDown: context.id == current.id ? nil : {
                                    NotificationCenter.default.post(
                                        name: .catusshTerminalSplitRequest,
                                        object: nil,
                                        userInfo: ["targetID": context.id, "axis": TerminalSplitAxis.vertical.rawValue]
                                    )
                                }
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
        let w = max(containerSize.width, 1)
        let h = max(containerSize.height, 1)
        let nx = pt.x / w
        let ny = pt.y / h
        if nx < 0.28 { return .left }
        if nx > 0.72 { return .right }
        if ny < 0.28 { return .top }
        if ny > 0.72 { return .bottom }
        return .center
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
        let all = store.snippetGroup.snippets
        guard !filter.isEmpty else { return all }
        let key = filter.lowercased()
        return all.filter {
            $0.name.lowercased().contains(key)
                || $0.code.lowercased().contains(key)
                || $0.group.lowercased().contains(key)
        }
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
    let number: Int?
    var shortcut: String?
    var onSplitRight: (() -> Void)?
    var onSplitDown: (() -> Void)?

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
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.rxInk : Color.rxInkSecondary)
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
            .opacity(selected || hovered ? 1 : 0)
            .accessibilityLabel("Close \(title)")
        }
        .frame(height: RX.controlHeight)
        .background {
            if selected {
                Capsule().fill(Color.primary.opacity(0.12))
            } else if hovered {
                Capsule().fill(Color.primary.opacity(0.06))
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            if let onSplitRight {
                Button("Split Right with Active Tab", action: onSplitRight)
            }
            if let onSplitDown {
                Button("Split Down with Active Tab", action: onSplitDown)
            }
            if onSplitRight != nil || onSplitDown != nil {
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

    var endpoint: String {
        if context.remoteType == .local { return "Local Shell · \(ProcessInfo.processInfo.hostName)" }
        if let command = context.command { return command.command }
        if context.machine.isUURemoteDevice { return "UU Remote · " + context.machine.name }
        return context.machine.getCommand(insertLeadingSSH: false)
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

extension TerminalManager.Context {
    @MainActor var tabSiblings: [TerminalManager.Context] {
        let all = TerminalManager.shared.sessionContexts
        switch remoteType {
        case .machine:
            return all.filter { $0.remoteType == .machine && $0.machine.id == machine.id }
        case .command:
            guard let command = command?.command else { return [self] }
            return all.filter { $0.remoteType == .command && $0.command?.command == command }
        case .local:
            return all.filter { $0.remoteType == .local }
        }
    }

    var displayName: String {
        switch remoteType {
        case .machine: return machine.name
        case .command:
            if let command { return "\(command.username)@\(command.remoteAddress)" }
            return navigationTitle
        case .local: return "Local Terminal"
        }
    }

    func reconnect() {
        guard closed else { return }
        DispatchQueue.global().async {
            self.putInformation("[i] Reconnecting with the details from when this session started.")
            self.putInformation("    If the server was edited, open a new terminal instead.")
            self.processBootstrap()
        }
    }
}
