//
//  ServersView.swift
//  mCatussh
//
//  Servers in their folders, with redaction, folders, ssh_config import and
//  Batch Startup.
//

import MachineStatusView
import CatusshModule
import SwiftUI

struct ServersView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var monitors = MonitorCenter.shared
    @State private var searchKey = ""
    @State private var openNewServer = false
    @State private var editing: RDMachine.ID?
    @State private var sshConfigSource: SSHConfigSource?

    var filtered: [RDMachine] {
        let all = store.machineGroup.machines
        guard !searchKey.isEmpty else { return all }
        return all.filter { $0.isQualifiedForSearch(text: searchKey.lowercased()) }
    }

    /// The folders in order, Default last; empty folders only while not
    /// searching.
    var groups: [(name: String, machines: [RDMachine])] {
        let machines = filtered
        var names = store.folders.map(\.name)
        if machines.contains(where: { $0.group.isEmpty }) { names.append("") }
        return names.compactMap { name in
            let inside = machines.filter { $0.group == name }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if inside.isEmpty, !searchKey.isEmpty { return nil }
            return (name, inside)
        }
    }

    var body: some View {
        Group {
            if store.machineGroup.machines.isEmpty, store.folders.isEmpty {
                EmptyStateView(
                    "No servers yet",
                    systemImage: "server.rack",
                    actionTitle: "New Server"
                ) {
                    openNewServer = true
                }
                .frame(maxHeight: .infinity)
                .background(RXBackdrop().ignoresSafeArea())
            } else {
                List {
                    if store.machineRedacted != .none {
                        Section {
                            HStack {
                                Image(systemName: "eye.slash").foregroundStyle(.rxInkSecondary)
                                Text(store.machineRedacted == .all ? "Names and addresses are hidden" : "Addresses are hidden")
                                    .font(.subheadline)
                                    .foregroundStyle(.rxInkSecondary)
                                Spacer()
                                Button("Show") { store.machineRedacted = .none }
                                    .font(.subheadline.weight(.semibold))
                            }
                            .rxListRow()
                        }
                    }
                    ForEach(groups, id: \.name) { group in
                        Section {
                            if group.machines.isEmpty {
                                Text(store.folder(named: group.name)?.isLinked == true ? "No desktop devices on the account" : "Empty — move servers here from their menu")
                                    .font(.footnote)
                                    .foregroundStyle(.rxInkSecondary)
                                    .rxListRow()
                            }
                            ForEach(group.machines) { machine in
                                ServerListRow(machine: machine.id, edit: { editing = machine.id })
                                    .rxListRow()
                            }
                        } header: {
                            FolderSectionHeader(name: group.name, count: group.machines.count)
                        }
                    }
                }
                .rxGroupedList()
                .searchable(text: $searchKey, prompt: "Search servers")
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Redaction", selection: $store.machineRedacted) {
                        Label("Show Everything", systemImage: "eye").tag(RDMachine.RedactedLevel.none)
                        Label("Hide Addresses", systemImage: "eye.slash").tag(RDMachine.RedactedLevel.sensitive)
                        Label("Hide Names and Addresses", systemImage: "eye.slash.fill").tag(RDMachine.RedactedLevel.all)
                    }
                    Divider()
                    Button {
                        FolderActions.newFolder()
                    } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                    }
                    SSHConfigImportMenuItems(source: $sshConfigSource)
                    Divider()
                    Button {
                        ServerActions.batchStartup()
                    } label: {
                        Label("Batch Startup", systemImage: "wind")
                    }
                    .disabled(store.machineGroup.machines.isEmpty)
                } label: {
                    Label("More", systemImage: store.machineRedacted == .none ? "ellipsis.circle" : "eye.slash")
                }
                Button {
                    openNewServer = true
                } label: {
                    Label("New Server", systemImage: "plus")
                }
            }
        }
        .sshConfigImporter($sshConfigSource)
        .sheet(isPresented: $openNewServer) {
            NavigationStack { EditMachineView() }
        }
        .sheet(item: Binding(get: { editing.map(EditTarget.init) }, set: { editing = $0?.id })) { target in
            NavigationStack { EditMachineView(requestMachine: target.id) }
        }
    }

    private struct EditTarget: Identifiable { let id: RDMachine.ID }
}

/// A server row: name, address, state; tap for actions.
struct ServerListRow: View {
    let machine: RDMachine.ID
    let edit: () -> Void
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var monitors = MonitorCenter.shared

    var body: some View {
        let read = store.machineGroup[machine]
        Menu {
            ServerMenuItems(machine: machine, edit: edit)
        } label: {
            HStack(spacing: RX.Space.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    RedactableText(read.name, redacted: store.machineRedacted == .all)
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                    if read.isUURemoteDevice {
                        Text("UU Remote")
                            .font(.footnote)
                            .foregroundStyle(.rxInkSecondary)
                    } else {
                        RedactableText(read.displayAddress, redacted: store.machineRedacted != .none)
                            .font(.rxCode)
                            .foregroundStyle(.rxInkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if let session = monitors.session(for: machine) {
                    ServerRowState(session: session)
                } else {
                    Text(RXFormat.relative(read.lastConnection))
                        .font(.footnote)
                        .foregroundStyle(.rxInkSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                ServerActions.delete(machine)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button(action: edit) {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.rxAccent)
        }
    }
}

private struct ServerRowState: View {
    @ObservedObject var session: MonitorSession
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if session.status.hasData {
                Text("CPU \(RXFormat.percent(Double(session.status.processor.summary.sumUsed)))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.rxInkSecondary)
            }
        }
    }
}

/// Open Terminal, Monitor, File Transfer; Edit, Move to Folder, Duplicate,
/// Copy, Forget Host Key, Check Terminfo Again; Delete.
struct ServerMenuItems: View {
    let machine: RDMachine.ID
    var edit: (() -> Void)?

    var body: some View {
        Section {
            Button { TerminalManager.shared.begin(for: machine) } label: {
                Label("Open Terminal", systemImage: "terminal")
            }
            Button { ServerActions.openMonitor(machine) } label: {
                Label("Open Monitor", systemImage: "waveform.path.ecg")
            }
            Button { FileTransferManager.shared.begin(for: machine) } label: {
                Label("Open File Transfer", systemImage: "arrow.up.arrow.down")
            }
            let read = CatusshStore.shared.machineGroup[machine]
            if read.hasRemoteDesktop {
                Button { ServerActions.openDesktop(machine) } label: {
                    Label("Open Remote Desktop", systemImage: "display")
                }
            }
            if read.remoteDesktopProtocol == .uuRemote, UULocalBridge.officialAppInstalled {
                Button { UULocalBridge.openControlInOfficialApp(for: read) } label: {
                    Label("UU Remote (PiP)", systemImage: "pip")
                }
            }
        }
        Section {
            if let edit {
                Button(action: edit) { Label("Edit", systemImage: "pencil") }
            }
            MoveToFolderMenu(machine: machine)
            Button { ServerActions.duplicate(machine) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }
        Section {
            let read = CatusshStore.shared.machineGroup[machine]
            if read.isUURemoteDevice {
                // Its address is the device id; no ssh command reaches it.
                Button { UIBridge.sendPasteboard(str: read.uuDeviceID) } label: {
                    Label("Copy Device ID", systemImage: "doc.on.doc")
                }
            } else {
                Button { UIBridge.sendPasteboard(str: "\(read.remoteAddress):\(read.remotePort)") } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                }
                Button { UIBridge.sendPasteboard(str: read.getCommand()) } label: {
                    Label("Copy SSH Command", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            Button { ServerActions.forgetHostKey(machine) } label: {
                Label("Forget Host Key", systemImage: "key.slash")
            }
            if read.hasGhosttyTerminfo {
                Button { ServerActions.reinstallTerminfo(machine) } label: {
                    Label("Check Terminfo Again", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        Section {
            Button(role: .destructive) { ServerActions.delete(machine) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

enum ServerActions {
    @MainActor
    static func openMonitor(_ machine: RDMachine.ID) {
        do {
            let existing = MonitorCenter.shared.session(for: machine)
            let session = try MonitorCenter.shared.begin(for: machine)
            // An existing monitor is brought forward even when sessions do
            // not open automatically; a new one waits for the setting.
            guard existing != nil || CatusshStore.shared.openInterfaceAutomatically else { return }
            let host = UIHostingController(rootView: DefaultModalPresenter {
                MonitorView(session: session)
            }.environmentObject(CatusshStore.shared))
            host.modalTransitionStyle = .coverVertical
            host.modalPresentationStyle = .formSheet
            host.preferredContentSize = preferredPopOverSize
            PresentationQueue.present(next: host)
        } catch {
            UIBridge.presentError(with: "Cannot open monitor")
        }
    }

    /// The server's remote desktop in a hosted stage view — full screen on
    /// iPhone, a large sheet on iPad, like the terminal.
    @MainActor
    static func openDesktop(_ machine: RDMachine.ID) {
        let existing = RemoteDesktopManager.shared.session(for: machine)
        let session = RemoteDesktopManager.shared.begin(for: machine)
        guard existing != nil || CatusshStore.shared.openInterfaceAutomatically else { return }
        let host = UIHostingController(rootView: DefaultModalPresenter {
            RemoteDesktopStageView(session: session)
        }.environmentObject(CatusshStore.shared))
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = UIDevice.current.userInterfaceIdiom == .phone ? .fullScreen : .formSheet
        host.preferredContentSize = preferredPopOverSize
        PresentationQueue.present(next: host)
    }

    static func duplicate(_ machine: RDMachine.ID) {
        var copy = CatusshStore.shared.machineGroup[machine]
        guard copy.isNotPlaceholder() else { return }
        copy.id = UUID()
        copy.name += " copy"
        CatusshStore.shared.machineGroup.insert(copy)
    }

    /// For a server whose keys were replaced: its next host key is saved.
    @MainActor
    static func forgetHostKey(_ machine: RDMachine.ID) {
        let read = CatusshStore.shared.machineGroup[machine]
        guard read.isNotPlaceholder() else { return }
        UIBridge.requiresConfirmation(message: "Forget the host key of \(read.name)? The key it presents next is saved as its key.") { confirmed in
            guard confirmed else { return }
            read.forgetHostKey()
        }
    }

    /// The next terminal checks the server for Ghostty's terminfo again and
    /// installs it if it is missing (say, after ~/.terminfo was cleared).
    @MainActor
    static func reinstallTerminfo(_ machine: RDMachine.ID) {
        var read = CatusshStore.shared.machineGroup[machine]
        guard read.isNotPlaceholder() else { return }
        read.forgetGhosttyTerminfo()
        CatusshStore.shared.machineGroup[machine] = read
    }

    @MainActor
    static func delete(_ machine: RDMachine.ID) {
        let name = CatusshStore.shared.machineGroup[machine].name
        UIBridge.requiresConfirmation(
            message: "Delete \(name)?",
            informative: "Port forwards through it stop working.",
            confirmTitle: "Delete"
        ) { confirmed in
            guard confirmed else { return }
            if let session = MonitorCenter.shared.session(for: machine) {
                MonitorCenter.shared.end(session.id)
            }
            CatusshStore.shared.machineGroup.delete(machine)
            CatusshStore.shared.cleanRecentIfNeeded()
        }
    }

    /// Pick servers, then open a terminal for each.
    static func batchStartup() {
        Task { @MainActor in
            let machines = await CatusshUtil.selectMachine()
            for machine in machines {
                TerminalManager.shared.begin(for: machine, force: true)
            }
        }
    }
}

private extension RDMachine {
    /// host, or host:port when the port is not 22.
    var displayAddress: String {
        remotePort.isEmpty || remotePort == "22" ? remoteAddress : "\(remoteAddress):\(remotePort)"
    }
}
