//
//  UURemoteSessionPickerView.swift
//  mCatussh
//
//  A UU Remote device keeps its terminal sessions after their tab is gone
//  (closed, catussh quit, or the connection dropped): one of them, or a new
//  one. Ending a session is done here and nowhere else.
//

import CatusshModule
import SwiftUI

struct UURemoteSessionPickerView: View {
    enum Choice { case new, resume(UInt32) }

    let machine: RDMachine
    /// nil when cancelled.
    let onComplete: (Choice?) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase { case loading, failed(String), loaded }

    @State private var phase = Phase.loading
    @State private var sessions: [UUTerminalSession] = []
    @State private var selection: UInt32?
    @State private var ending: UUTerminalSession?
    @State private var status = ""

    /// Presents the picker over the app; `onComplete` hears the choice once.
    @MainActor
    static func present(machine: RDMachine, onComplete: @escaping (Choice?) -> Void) {
        let picker = NavigationStack {
            UURemoteSessionPickerView(machine: machine, onComplete: onComplete)
        }
        .tint(.rxAccent)
        CatusshUtil.presentModalSheet(rootView: picker) { presented in
            if !presented { onComplete(nil) }
        }
    }

    var body: some View {
        content
            .background(RXBackdrop().ignoresSafeArea())
            .navigationTitle("Terminal on \(machine.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(nil) }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("New Session") { finish(.new) }
                        .keyboardShortcut("n", modifiers: .command)
                    Button {
                        if let selection { finish(.resume(selection)) }
                    } label: {
                        Text("Resume").bold()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
                }
            }
            .task { await load() }
            .alert(
                "End \(ending?.name ?? "the session")?",
                isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                presenting: ending
            ) { session in
                Button("End Session", role: .destructive) { Task { await end(session) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its shell, and whatever runs in it, stops on \(machine.name).")
            }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            VStack(spacing: RX.Space.s2) {
                ProgressView()
                Text(status.isEmpty ? "Connecting to \(machine.name)…" : status)
                    .font(.footnote)
                    .foregroundStyle(.rxInkSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(reason):
            EmptyStateView(
                "Sessions could not be listed",
                systemImage: "exclamationmark.triangle",
                message: reason,
                actionTitle: "Try Again"
            ) {
                Task { await load() }
            }
            .frame(maxHeight: .infinity)
        case .loaded:
            List {
                Section {
                    ForEach(sessions) { session in
                        row(session)
                            .rxListRow()
                            .swipeActions {
                                Button("End Session", role: .destructive) { ending = session }
                            }
                            .contextMenu {
                                Button { finish(.resume(session.id)) } label: {
                                    Label("Resume", systemImage: "play")
                                }
                                Button(role: .destructive) { ending = session } label: {
                                    Label("End Session…", systemImage: "xmark.octagon")
                                }
                            }
                    }
                } footer: {
                    Text("A session keeps running on the device after its tab closes, until you end it here. Resume one, or start a new one.")
                }
            }
            .rxGroupedList()
        }
    }

    private func row(_ session: UUTerminalSession) -> some View {
        let isSelected = selection == session.id
        return Button {
            selection = session.id
        } label: {
            HStack(spacing: RX.Space.s3) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Color.rxAccent : Color.rxInkTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .foregroundStyle(.rxInk)
                    Text("Last used \(Self.relative(session.lastActive)) · started \(session.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.rxInkSecondary)
                }
                Spacer()
                if !session.isDetached {
                    RXTag("Attached")
                }
                if !session.shell.isEmpty { RXTag(session.shell) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func finish(_ choice: Choice?) {
        dismiss()
        onComplete(choice)
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func load() async {
        phase = .loading
        let watch = Task { @MainActor in
            while !Task.isCancelled {
                status = UURemoteConnections.shared.status(for: machine)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { watch.cancel() }
        do {
            let available = try await TerminalManager.shared.resumableUUSessions(for: machine)
            // Nothing to resume: straight to a new one.
            if available.isEmpty {
                finish(.new)
                return
            }
            sessions = available
            if selection.map({ id in !available.contains { $0.id == id } }) ?? true {
                selection = (available.first(where: \.isDetached) ?? available.first)?.id
            }
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func end(_ session: UUTerminalSession) async {
        do {
            try await UURemoteConnections.shared.endSession(session.id, on: machine)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        sessions.removeAll { $0.id == session.id }
        if selection == session.id { selection = sessions.first?.id }
        if sessions.isEmpty { finish(.new) }
    }
}
