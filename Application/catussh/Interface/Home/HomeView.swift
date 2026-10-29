//
//  HomeView.swift
//  catussh (macOS)
//
//  Start page: Quick Connect (the typed command parsed into user, host and port),
//  Recent, then the Servers grid. Every tile is the same size and names its
//  actions: Connect, Files, Monitor.
//

import MachineStatusView
import CatusshModule
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: CatusshStore

    var body: some View {
        ScrollView {
            VStack(spacing: RX.Space.s6) {
                QuickConnectHero()
                    .padding(.top, 72)
                    .padding(.bottom, RX.Space.s6)
                serversSection
            }
            .padding(.horizontal, RX.Space.s6)
            .padding(.bottom, RX.Space.s6)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: store.machineGroup.machines.map(\.id))
        }
        .pageChrome()
        // No toolbar "+": the grid ends in the New Server tile (and the empty
        // state offers it), so a second button would do the same thing.
    }

    @ViewBuilder var serversSection: some View {
        if store.machineGroup.machines.isEmpty {
            EmptyStateView(
                "Save a server to reach it in one click",
                systemImage: "server.rack",
                message: "Saved servers keep their address, port and identity, and open a terminal, files or a monitor.",
                actionTitle: "New Server"
            ) {
                AppRouter.shared.presentNewServer = true
            }
            .frame(maxWidth: 640)
            .rxCard()
        } else {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                // Every server is in the grid; the sidebar's Servers has the
                // count and the table.
                SectionTitle("Servers")
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 310), spacing: RX.Space.s4)],
                    spacing: RX.Space.s4
                ) {
                    ForEach(Array(store.machineGroup.machines.enumerated()), id: \.element.id) { index, machine in
                        ServerTile(machine: machine.id)
                            .rxRise(index)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    NewServerTile()
                }
            }
        }
    }
}

// MARK: - Quick Connect

/// The big, fast way in: type `user@host` and press Return. Focused on open.
/// What was typed is read back as separate User, Host and Port tokens, so it is
/// clear what Return will connect to before pressing it.
struct QuickConnectHero: View {
    @EnvironmentObject var store: CatusshStore
    @State private var command = ""
    @State private var suggestion: String?
    @FocusState private var focused: Bool

    var parsed: SSHCommandReader? {
        SSHCommandReader(quickConnect: command)
    }

    var body: some View {
        let parsed = parsed
        VStack(spacing: RX.Space.s4) {
            HStack(spacing: RX.Space.s3) {
                Image(systemName: "terminal")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.rxInkSecondary)
                    .accessibilityHidden(true)
                TextField("user@host:22", text: $command)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .regular, design: .monospaced))
                    .disableAutocorrection(true)
                    .focused($focused)
                    .onSubmit(connect)
                    .onChange(of: command) { newValue in
                        if newValue.hasPrefix("ssh ssh ") { command.removeFirst("ssh ".count) }
                        refreshSuggestion()
                    }
                    .accessibilityLabel("Quick Connect")
                Button(action: connect) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.rxOnAccent)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.rxAccent))
                }
                .buttonStyle(.plain)
                .disabled(parsed == nil)
                .opacity(parsed == nil ? 0.35 : 1)
                .scaleEffect(parsed == nil ? 0.9 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: parsed == nil)
                .help("Connect (↩)")
                .accessibilityLabel("Connect")
            }
            .padding(.leading, RX.Space.s5)
            .padding(.trailing, RX.Space.s2)
            .frame(height: 64)
            .background(
                Capsule()
                    .fill(Color.rxSurface)
                    .overlay(Capsule().strokeBorder(focused ? Color.clear : Color.rxHairline, lineWidth: 0.5))
                    .overlay(Capsule().strokeBorder(Color.rxAccent.opacity(focused ? 0.5 : 0), lineWidth: 1.5))
                    .shadow(color: .black.opacity(focused ? 0.12 : 0.06), radius: focused ? 14 : 10, y: 4)
            )
            .animation(.easeOut(duration: 0.2), value: focused)
            .frame(maxWidth: 640)

            Group {
                if let parsed {
                    ParsedCommand(command: parsed)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                } else if !"ssh ".hasPrefix(command.lowercased()) {
                    Text("Type user@host, user@host:port or a full ssh command.")
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: parsed)

            if let suggestion {
                Button {
                    command = suggestion
                    connect()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                        Text(suggestion).font(.system(size: 13, design: .monospaced))
                        KeyHint("⌘↩")
                    }
                    .foregroundStyle(.rxInkSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Connect with this recent command")
                .transition(.opacity)
            }

            if store.identityGroupForAutoAuth.isEmpty {
                HStack(spacing: RX.Space.s2) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("Quick Connect signs in with identities set to “Authenticate automatically”. You have none yet.")
                    Button("Open Identities") { AppRouter.shared.route = .identities }
                        .rxLinkButton()
                }
                .font(.rxHelp)
                .foregroundStyle(.rxWarning)
            }

            if store.storeRecent, store.recentRecord.contains(where: \.isCommand) {
                VStack(spacing: RX.Space.s2) {
                    CapsLabel("Recent")
                    RXFlowLayout(spacing: RX.Space.s2, alignment: .center) {
                        // Saved servers are in the grid below; Recent keeps the
                        // Quick Connect commands, which have nowhere else.
                        ForEach(store.recentRecord.filter(\.isCommand)) { record in
                            RecentChip(record: record)
                        }
                    }
                }
                .frame(maxWidth: 640)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: suggestion)
        .onAppear {
            onMainThread(delay: 0.2) { focused = true }
        }
    }

    func connect() {
        guard let parsed else { return }
        AppRouter.shared.openTerminal(command: parsed)
        command = ""
    }

    func refreshSuggestion() {
        suggestion = SSHCommandReader.suggestion(
            for: command,
            in: store.recentRecord.lazy.map(\.equivalentSSHCommand)
        )
    }
}

/// The parsed command as distinct tokens: who, where, which port.
private struct ParsedCommand: View {
    let command: SSHCommandReader

    var body: some View {
        HStack(spacing: RX.Space.s2) {
            token("User", command.username, systemImage: "person", tint: .rxAccent)
            token("Host", command.remoteAddress, systemImage: "network", tint: .rxSeries2)
            token("Port", command.remotePort, systemImage: "number", tint: .rxInkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    func token(_ title: String, _ value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(title.uppercased())
                .font(.rxCaption)
                .tracking(rxCapsTracking)
                .foregroundStyle(.rxInkSecondary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.rxInk)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}

/// A recent server or command; one click connects.
struct RecentChip: View {
    let record: CatusshStore.RecentConnection
    @EnvironmentObject var store: CatusshStore
    @State private var hovered = false

    var title: String {
        switch record {
        case let .command(command):
            // Only the leading "ssh " is decoration; one inside the
            // arguments is part of the command.
            var title = command.command
            if title.hasPrefix("ssh ") { title.removeFirst("ssh ".count) }
            return title
        case let .machine(id):
            let machine = store.machineGroup[id]
            return machine.isNotPlaceholder() ? machine.name : "Deleted server"
        }
    }

    var body: some View {
        Button(action: connect) {
            HStack(spacing: 6) {
                Image(systemName: isCommand ? "terminal" : "server.rack")
                    .font(.system(size: 11))
                RedactableText(title, redacted: !isCommand && store.machineRedacted == .all)
                    .font(.system(size: 12, design: isCommand ? .monospaced : .default))
                    .lineLimit(1)
            }
            .foregroundStyle(.rxInk)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(hovered ? 0.12 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy Command") { UIBridge.sendPasteboard(str: record.equivalentSSHCommand) }
            Divider()
            Button("Remove from Recent", role: .destructive) {
                store.recentRecord.removeAll { $0.id == record.id }
            }
        }
    }

    var isCommand: Bool {
        if case .command = record { return true }
        return false
    }

    func connect() {
        switch record {
        case let .command(command): AppRouter.shared.openTerminal(command: command)
        case let .machine(machine): AppRouter.shared.openTerminal(machine: machine)
        }
    }
}

// MARK: - Tiles

/// Every tile in the grid, the New Server tile included, has this height, so rows
/// line up whether or not a server is being monitored.
private let serverTileHeight: CGFloat = 168

/// A server at a glance: name, address, state, CPU and memory while monitored,
/// and its actions by name. Clicking the tile connects; right-click for more.
struct ServerTile: View {
    let machine: RDMachine.ID
    @EnvironmentObject var store: CatusshStore
    // Observed so the dot follows a terminal opening or closing, the same
    // subscription SessionTabs makes.
    @ObservedObject var terminals = TerminalManager.shared
    @State private var hovered = false

    var body: some View {
        let read = store.machineGroup[machine]
        ServerLiveReader(machine: machine) { state in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: RX.Space.s2) {
                    VStack(alignment: .leading, spacing: 2) {
                        RedactableText(read.name, redacted: store.machineRedacted == .all)
                            .font(.rxBodyStrong)
                            .foregroundStyle(.rxInk)
                            .lineLimit(1)
                        RedactableText(read.remoteAddress, redacted: store.machineRedacted != .none)
                            .font(.rxCode)
                            .foregroundStyle(.rxInkSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: RX.Space.s2)
                    if connected {
                        StatusDot(.success, size: .small)
                            .padding(.top, 6)
                            .help("A terminal is open")
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Spacer(minLength: RX.Space.s2)
                Group {
                    if let cpu = state.cpu, let memory = state.memory {
                        VStack(spacing: 6) {
                            tileBar("CPU", percent: cpu, color: .rxAccent)
                            tileBar("Memory", percent: memory, color: .rxSeries2)
                        }
                        .transition(.opacity)
                    } else {
                        VStack(spacing: 6) {
                            infoRow("Last used", RXFormat.relative(read.lastConnection))
                            infoRow("Identity", identityName(read))
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.25), value: state.cpu == nil)
                Spacer(minLength: RX.Space.s3)
                actions
            }
            .frame(height: serverTileHeight - RX.Space.s4 * 2)
        }
        .rxCard()
        .overlay(
            RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                .strokeBorder(Color.rxAccent.opacity(hovered ? 0.35 : 0), lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovered ? 0.12 : 0), radius: 16, y: 8)
        .scaleEffect(hovered ? 1.01 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovered)
        .contentShape(RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous))
        .onHover { hovered = $0 }
        .onTapGesture { connect() }
        .contextMenu { ServerContextMenu(machine: machine) }
        .help("Click to open a terminal")
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
    }

    var connected: Bool {
        terminals.sessionContexts.contains { $0.remoteType == .machine && $0.machine.id == machine && !$0.closed }
    }

    var actions: some View {
        HStack(spacing: RX.Space.s1) {
            // Named like the page switcher: Terminal, Files, Monitor.
            Button(action: connect) {
                Label(ServerTool.terminal.title, systemImage: ServerTool.terminal.systemImage)
            }
            .buttonStyle(.rx(.primary, size: .small))
            .help(ServerTool.terminal.help)
            toolButton(.files)
            toolButton(.monitor)
            if CatusshStore.shared.machineGroup[machine].hasRemoteDesktop {
                toolButton(.desktop)
            }
            Spacer(minLength: 0)
            Menu {
                ServerContextMenu(machine: machine, includesTools: false)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.rx(.plain, size: .small, iconOnly: true))
            .fixedSize()
            .help("More actions")
        }
    }

    func toolButton(_ tool: ServerTool) -> some View {
        Button {
            tool.show(machine)
        } label: {
            Label(tool.title, systemImage: tool.systemImage)
        }
        .buttonStyle(.rx(size: .small))
        .help(tool.help)
    }

    /// Shows the server's terminal, opening one if none is open.
    func connect() {
        ServerTool.terminal.show(machine)
    }

    func identityName(_ machine: RDMachine) -> String {
        guard let aid = machine.associatedIdentity, let uid = UUID(uuidString: aid) else { return "Automatic" }
        let identity = store.identityGroup[uid]
        return identity.username.isEmpty ? "Missing" : identity.username
    }

    func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            CapsLabel(title)
            Spacer()
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
        }
        .frame(height: 16)
    }

    func tileBar(_ title: String, percent: Double, color: Color) -> some View {
        HStack(spacing: RX.Space.s2) {
            CapsLabel(title)
                .frame(width: 56, alignment: .leading)
            UsageBar(fraction: percent / 100, color: color)
            Text("\(RXFormat.percent(percent))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 16)
    }
}

/// The dashed tile that ends the server grid, the same size as a server tile.
struct NewServerTile: View {
    @State private var hovered = false

    var body: some View {
        Button {
            AppRouter.shared.presentNewServer = true
        } label: {
            VStack(spacing: RX.Space.s2) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .scaleEffect(hovered ? 1.15 : 1)
                Text("New Server")
                    .font(.rxBody)
            }
            .foregroundStyle(hovered ? Color.rxAccent : Color.rxInkSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: serverTileHeight)
            .background(
                RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(hovered ? Color.rxAccent : Color.rxControlBorder)
            )
            .background(
                RoundedRectangle(cornerRadius: RX.Radius.card, style: .continuous)
                    .fill(Color.rxAccent.opacity(hovered ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .help("Add a server")
    }
}

extension CatusshStore.RecentConnection {
    /// A Quick Connect command rather than a saved server.
    var isCommand: Bool {
        if case .command = self { return true }
        return false
    }
}
