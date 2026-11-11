//
//  HomeView.swift
//  mCatussh
//
//  Home: a big Quick Connect, recent connections, server tiles.
//

import MachineStatusView
import CatusshModule
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var monitors = MonitorCenter.shared
    @State private var openNewServer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RX.Space.s6) {
                QuickConnectCard()
                if store.storeRecent, !store.recentRecord.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: RX.Space.s2) {
                            ForEach(store.recentRecord) { record in
                                RecentRow(record: record)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: RX.Space.s3) {
                    SectionTitle("Servers", count: store.machineGroup.count) {
                        if !store.machineGroup.machines.isEmpty {
                            Button {
                                ServerActions.batchStartup()
                            } label: {
                                Label("Batch Startup", systemImage: "wind")
                            }
                            .buttonStyle(.rx(size: .small))
                        }
                    }
                    if store.machineGroup.machines.isEmpty {
                        EmptyStateView(
                            "No servers yet",
                            systemImage: "server.rack",
                            actionTitle: "New Server"
                        ) {
                            openNewServer = true
                        }
                        .rxCard()
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: RX.Space.s3)], spacing: RX.Space.s3) {
                            ForEach(store.machineGroup.machines) { machine in
                                ServerTile(machine: machine.id)
                            }
                        }
                    }
                }
                Text(appVersion)
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkTertiary)
                    .frame(maxWidth: .infinity)
            }
            .padding(RX.Space.s4)
        }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem {
                Button {
                    openNewServer = true
                } label: {
                    Label("New Server", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $openNewServer) {
            NavigationStack { EditMachineView() }
        }
    }
}

/// Type `user@host:port` or a full ssh command and connect. Uses identities that authenticate automatically.
struct QuickConnectCard: View {
    @EnvironmentObject var store: CatusshStore
    @State private var command = ""
    @State private var suggestion: String?
    @State private var importData: Data?

    var parsed: SSHCommandReader? {
        SSHCommandReader(quickConnect: command)
    }

    var body: some View {
        VStack(spacing: RX.Space.s3) {
            HStack(spacing: RX.Space.s2) {
                Image(systemName: "terminal")
                    .font(.system(size: 18))
                    .foregroundStyle(.rxInkSecondary)
                TextField("ssh user@host -p 22", text: $command)
                    .font(.system(size: 19, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit(connect)
                    .onChange(of: command) { newValue in
                        if newValue.hasPrefix("ssh ssh ") { command.removeFirst("ssh ".count) }
                        refreshSuggestion()
                    }
                Button(action: connect) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.rxOnAccent)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.rxAccent))
                }
                .disabled(parsed == nil)
                .opacity(parsed == nil ? 0.35 : 1)
                .simultaneousGesture(LongPressGesture().onEnded { _ in importFromPasteboard() })
                .accessibilityLabel("Connect")
            }
            .padding(.leading, RX.Space.s4)
            .padding(.trailing, 6)
            .frame(height: 56)
            .background(
                Capsule()
                    .fill(.thickMaterial)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            )
            if let suggestion {
                Button {
                    command = suggestion
                    connect()
                } label: {
                    Label(suggestion, systemImage: "arrow.turn.down.right")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                }
            }
            if store.identityGroupForAutoAuth.isEmpty {
                Text("Needs an identity that authenticates automatically.")
                    .font(.footnote)
                    .foregroundStyle(.rxWarning)
            }
        }
        .padding(.vertical, RX.Space.s5)
    }

    func connect() {
        guard let parsed else { return }
        TerminalManager.shared.begin(for: parsed)
        command = ""
    }

    func refreshSuggestion() {
        suggestion = SSHCommandReader.suggestion(
            for: command,
            in: store.recentRecord.lazy.map(\.equivalentSSHCommand)
        )
    }

    /// Hidden importer kept from the original app: long-press Connect with the
    /// exported data, then again with its key, on the pasteboard.
    func importFromPasteboard() {
        guard let paste = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if let data = importData {
            importData = nil
            CatusshStore.overrideImport(from: data, key: paste)
        } else if let data = Data(base64Encoded: paste) {
            importData = data
        }
    }
}

/// A server at a glance: name, address, state, CPU and memory while monitored.
struct ServerTile: View {
    let machine: RDMachine.ID
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var monitors = MonitorCenter.shared

    var body: some View {
        let read = store.machineGroup[machine]
        Menu {
            ServerMenuItems(machine: machine)
        } label: {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        RedactableText(read.name, redacted: store.machineRedacted == .all)
                            .font(.headline)
                            .foregroundStyle(.rxInk)
                            .lineLimit(1)
                        RedactableText(read.remoteAddress, redacted: store.machineRedacted != .none)
                            .font(.rxCode)
                            .foregroundStyle(.rxInkSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                if let session = monitors.session(for: machine) {
                    LiveTileBars(session: session)
                } else {
                    HStack {
                        CapsLabel("Last used")
                        Spacer()
                        Text(RXFormat.relative(read.lastConnection))
                            .font(.footnote)
                            .foregroundStyle(.rxInkSecondary)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .rxCard()
        }
        .buttonStyle(.plain)
    }
}

private struct LiveTileBars: View {
    @ObservedObject var session: MonitorSession
    var body: some View {
        let cpu = Double(session.status.processor.summary.sumUsed)
        let memory = session.status.memoryUsedPercent
        VStack(spacing: RX.Space.s2) {
            bar("CPU", cpu, .rxAccent)
            bar("Memory", memory, .rxSeries2)
        }
    }

    func bar(_ title: String, _ percent: Double, _ color: Color) -> some View {
        HStack(spacing: RX.Space.s2) {
            CapsLabel(title).frame(width: 56, alignment: .leading)
            UsageBar(fraction: percent / 100, color: color)
            Text("\(RXFormat.percent(percent))%")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// A recent server or command as a chip; a tap connects.
struct RecentRow: View {
    let record: CatusshStore.RecentConnection
    @EnvironmentObject var store: CatusshStore

    var body: some View {
        Button(action: connect) {
            HStack(spacing: 6) {
                switch record {
                case let .command(command):
                    Image(systemName: "terminal")
                    Text(command.command.replacingOccurrences(of: "ssh ", with: ""))
                        .font(.system(size: 13, design: .monospaced))
                case let .machine(id):
                    let machine = store.machineGroup[id]
                    Image(systemName: "server.rack")
                    RedactableText(machine.isNotPlaceholder() ? machine.name : "Deleted server", redacted: store.machineRedacted == .all)
                        .font(.system(size: 13))
                }
            }
            .lineLimit(1)
            .foregroundStyle(.rxInk)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Command") { UIBridge.sendPasteboard(str: record.equivalentSSHCommand) }
            Button("Remove from Recent", role: .destructive) {
                store.recentRecord.removeAll { $0.id == record.id }
            }
        }
    }

    func connect() {
        switch record {
        case let .command(command): TerminalManager.shared.begin(for: command)
        case let .machine(machine): ServerActions.openTerminal(machine)
        }
    }
}
