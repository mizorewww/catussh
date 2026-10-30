//
//  TerminalPage.swift
//  catussh (macOS)
//
//  A terminal inside the main window: tabs for this server's terminals (closing
//  is the tab's button), the Terminal · Files · Monitor switcher, text size and
//  Reconnect. Status bar: the endpoint, then live figures while monitored.
//

import MachineStatusView
import CatusshModule
import CatusshTerminal
import SwiftUI

struct TerminalPage: View {
    @ObservedObject var context: TerminalManager.Context
    @EnvironmentObject var store: CatusshStore

    @State private var interfaceToken = UUID()
    @Environment(\.isActivePage) private var isActive

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if context.closed {
                    disconnectedBanner
                }
                surface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // No backdrop of our own: Ghostty paints its background with
            // `background-opacity`, so a translucent terminal shows the window
            // material underneath instead of an opaque fill.
            .clipShape(RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous))
            .padding(.horizontal, RX.Space.s6)
            TerminalStatusBar(context: context)
                .padding(.horizontal, RX.Space.s6)
        }
        .padding(.top, RX.Space.s3)
        .pageChrome()
        // Closing is the tab's close button; no second one here.
        .pageToolbar(
            primary: context.closed
                ? ToolbarAction("Reconnect", systemImage: "arrow.clockwise", primary: true) { context.reconnect() }
                : nil,
            trailingMetrics: .controlGroup
        ) {
            SessionTabs(current: context)
        } trailing: {
            Group {
                Button {
                    store.terminalFontSize -= 1
                } label: {
                    Label("Smaller Text", systemImage: "textformat.size.smaller")
                }
                .disabled(store.terminalFontSize <= 4)
                .keyboardShortcut("-", modifiers: .command)
                .accessibilityLabel("Smaller Text")
                Button {
                    store.terminalFontSize += 1
                } label: {
                    Label("Larger Text", systemImage: "textformat.size.larger")
                }
                .disabled(store.terminalFontSize >= 30)
                .keyboardShortcut("+", modifiers: .command)
                .accessibilityLabel("Larger Text")
            }
            .help("Text Size")
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
            Text("Connection closed")
                .foregroundStyle(.rxTerminalForeground)
            Spacer()
        }
        .font(.rxBody)
        .padding(.horizontal, RX.Space.s3)
        .frame(height: 36)
        .background(Color.black.opacity(0.35))
    }
}

/// Tabs for this server's terminals (a Quick Connect terminal has only its own).
/// The sidebar lists servers; these tabs pick among one server's terminals.
struct SessionTabs: View {
    @ObservedObject var current: TerminalManager.Context
    @ObservedObject var terminals = TerminalManager.shared

    private var siblings: [TerminalManager.Context] { current.tabSiblings }

    var body: some View {
        HStack(spacing: RX.Space.s1) {
            // The tabs scroll where the toolbar is short of room; the one in
            // front is always scrolled into view, and "+" stays outside.
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RX.Space.s1) {
                        let siblings = siblings
                        ForEach(Array(siblings.enumerated()), id: \.element.id) { index, context in
                            SessionTab(context: context, selected: context.id == current.id, number: siblings.count > 1 ? index + 1 : nil)
                                .id(context.id)
                        }
                    }
                }
                .onAppear { reader.scrollTo(current.id) }
                .onChange(of: current.id) { id in withAnimation(.rxQuick) { reader.scrollTo(id) } }
                .onChange(of: siblings.count) { _ in withAnimation(.rxQuick) { reader.scrollTo(current.id) } }
            }
            Button {
                if current.remoteType == .machine {
                    // "+" says what it wants: another tab, without asking.
                    AppRouter.shared.openTerminal(machine: current.machine.id, another: true)
                } else if let command = current.command {
                    AppRouter.shared.openTerminal(command: command)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.rxInkSecondary)
            .help("New Terminal")
            .accessibilityLabel("New Terminal")
        }
        // With the toolbar capsule's own inset, 4pt from its ends.
        .padding(.horizontal, 2.25)
        .frame(maxWidth: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SessionTab: View {
    /// UIKit draws a bold xmark larger than AppKit does at the same size.
    #if targetEnvironment(macCatalyst)
        private static let closeGlyphSize: CGFloat = 7
    #else
        private static let closeGlyphSize: CGFloat = 9
    #endif

    @ObservedObject var context: TerminalManager.Context
    let selected: Bool
    /// Position among the server's terminals, when there is more than one.
    let number: Int?

    /// The server is already named in the sidebar and title; the tab names the
    /// shell (its title, usually user@host: path), else its number.
    private var title: String {
        if !context.navigationSubtitle.isEmpty { return context.navigationSubtitle }
        if let number { return "Terminal \(number)" }
        return context.remoteType == .machine ? "Terminal" : context.displayName
    }
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.rxInk : Color.rxInkSecondary)
                .lineLimit(1)
                .frame(maxWidth: 160)
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
            .opacity(selected || hovered ? 1 : 0)
            .accessibilityLabel("Close \(title)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: RX.controlHeight)
        .background {
            if selected {
                Capsule().fill(Color.primary.opacity(0.1))
            } else if hovered {
                Capsule().fill(Color.primary.opacity(0.05))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { AppRouter.shared.route = .terminal(context.id) }
        .onHover { hovered = $0 }
        .contextMenu {
            if context.closed { Button("Reconnect") { context.reconnect() } }
            Button("Close Session") { TerminalSessionActions.close(context) }
        }
    }
}

/// State, user@host:port, live CPU and memory while a monitor is open, font size.
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
        if let command = context.command { return command.command }
        // Its address would be the device id; it is reached by name.
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
    /// ⌘W on a terminal: closes the tab. The server's last tab is replaced by
    /// a fresh terminal to the same server, so the page stays open.
    @MainActor
    static func closeTab(_ context: TerminalManager.Context) {
        let manager = TerminalManager.shared
        let replace = context.tabSiblings.count == 1
        let perform = {
            // Asked twice, answered twice: only the first closes anything.
            guard manager.sessionContexts.contains(where: { $0.id == context.id }) else { return }
            if replace, let fresh = openReplacement(for: context) {
                AppRouter.shared.route = .terminal(fresh.id)
            } else {
                showNeighbour(of: context)
            }
            manager.closeSession(withContextID: context.id)
        }
        if manager.sessionAlive(forContext: context.id) {
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

    /// A new terminal like the one closing: the same saved server, or the same
    /// Quick Connect command.
    @MainActor
    private static func openReplacement(for context: TerminalManager.Context) -> TerminalManager.Context? {
        let manager = TerminalManager.shared
        if context.remoteType == .machine {
            let machine = CatusshStore.shared.machineGroup[context.machine.id]
            guard machine.isNotPlaceholder() else { return nil }
            var created: TerminalManager.Context?
            manager.createSession(withMachineObject: machine, force: true) { created = $0 }
            return created
        }
        return context.command.map { manager.createSession(withCommand: $0) }
    }

    @MainActor
    static func close(_ context: TerminalManager.Context) {
        let manager = TerminalManager.shared
        let perform = {
            showNeighbour(of: context)
            manager.closeSession(withContextID: context.id)
        }
        if manager.sessionAlive(forContext: context.id) {
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

    /// A tab closing in front hands the page to the tab after it (or before
    /// it, at the end), or the last one to the server's open desktop, so the
    /// server stays on screen.
    @MainActor
    private static func showNeighbour(of context: TerminalManager.Context) {
        guard AppRouter.shared.route == .terminal(context.id) else { return }
        let siblings = context.tabSiblings
        guard let index = siblings.firstIndex(where: { $0.id == context.id }), siblings.count > 1 else {
            // The last terminal: the server's desktop, if one is open, rather
            // than leaving its pages altogether.
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
    /// The terminals shown as tabs beside this one: the server's terminals, or
    /// only this one for Quick Connect.
    @MainActor var tabSiblings: [TerminalManager.Context] {
        guard remoteType == .machine else { return [self] }
        return TerminalManager.shared.sessionContexts.filter { $0.remoteType == .machine && $0.machine.id == machine.id }
    }

    /// The server's name, or `user@host` for a Quick Connect session.
    var displayName: String {
        if remoteType == .machine { return machine.name }
        if let command { return "\(command.username)@\(command.remoteAddress)" }
        return navigationTitle
    }

    /// Reconnects with the details from when this session started.
    func reconnect() {
        guard closed else { return }
        DispatchQueue.global().async {
            self.putInformation("[i] Reconnecting with the details from when this session started.")
            self.putInformation("    If the server was edited, open a new terminal instead.")
            self.processBootstrap()
        }
    }
}
