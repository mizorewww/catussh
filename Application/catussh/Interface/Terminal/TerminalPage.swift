//
//  TerminalPage.swift
//  catussh (macOS)
//

import CatusshModule
import CatusshTerminal
import MachineStatusView
import SwiftUI

struct TerminalPage: View {
    @ObservedObject var context: TerminalManager.Context
    @EnvironmentObject var store: CatusshStore

    @State private var interfaceToken = UUID()
    @Environment(\.isActivePage) private var isActive

    var body: some View {
        VStack(spacing: 0) {
            if context.tabSiblings.count > 1 {
                HStack(spacing: RX.Space.s2) {
                    SessionTabs(current: context)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, RX.Space.s6)
                .padding(.bottom, RX.Space.s2)
            }
            VStack(spacing: 0) {
                if context.closed {
                    disconnectedBanner
                }
                surface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                    .strokeBorder(Color.rxHairline, lineWidth: 1)
            )
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
                if context.remoteType == .machine {
                    AppRouter.shared.openTerminal(machine: context.machine.id, another: true)
                } else if let command = context.command {
                    AppRouter.shared.openTerminal(command: command)
                }
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
                                shortcut: siblings.count > 1 ? Self.shortcut(index: index, count: siblings.count) : nil
                            )
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
            .help("New Terminal (⌘T)")
            .accessibilityLabel("New Terminal")
        }
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
        if remoteType == .machine {
            return all.filter { $0.remoteType == .machine && $0.machine.id == machine.id }
        }
        guard let command = command?.command else { return [self] }
        return all.filter { $0.remoteType == .command && $0.command?.command == command }
    }

    var displayName: String {
        if remoteType == .machine { return machine.name }
        if let command { return "\(command.username)@\(command.remoteAddress)" }
        return navigationTitle
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
