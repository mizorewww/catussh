//
//  SnippetExecuteView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/4.
//
//  Running one snippet on several servers, on the shared
//  BatchSnippetExecContext like the Mac's BatchRunSheet: per-server state
//  and time (Done `success`, Running `accent`, Failed `danger`), that
//  server's output, overall progress, Stop and Done. The servers sit beside
//  the output on iPad and above it on iPhone.
//

import CatusshModule
import CatusshTerminal
import Combine
import SwiftUI

struct SnippetExecuteView: View {
    let snippet: RDSnippet
    let machines: [RDMachine.ID]

    @StateObject private var context: BatchSnippetExecContext
    @State private var selection: RDMachine.ID?
    @State private var tick = Date()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(snippet: RDSnippet, machines: [RDMachine.ID]) {
        self.snippet = snippet
        self.machines = machines
        _context = StateObject(wrappedValue: BatchSnippetExecContext(snippet: snippet, machines: machines))
        _selection = State(initialValue: machines.first)
    }

    var completedCount: Int { context.completedCount }
    var finished: Bool { completedCount >= machines.count }

    var body: some View {
        VStack(alignment: .leading, spacing: RX.Space.s3) {
            if horizontalSizeClass == .compact {
                serverList
                    .frame(maxHeight: 180)
                output
            } else {
                HStack(alignment: .top, spacing: RX.Space.s3) {
                    serverList
                        .frame(width: 240)
                    output
                }
            }
            RXProgressBar(machines.isEmpty ? 1 : Double(completedCount) / Double(machines.count))
            Text("\(completedCount) of \(machines.count) finished")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
        }
        .padding(RX.Space.s4)
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle("Run \(snippet.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !finished {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stop") { context.stopAll() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    done()
                } label: {
                    Text("Done").bold()
                }
            }
        }
        .onAppear { context.start() }
        .onReceive(timer) { date in
            if !finished { tick = date }
        }
    }

    func done() {
        if finished {
            dismiss()
            return
        }
        UIBridge.requiresConfirmation(
            message: "Stop running \(snippet.name)?",
            confirmTitle: "Stop and Close"
        ) { confirmed in
            guard confirmed else { return }
            context.stopAll()
            dismiss()
        }
    }

    var serverList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(machines, id: \.self) { machine in
                    let state = context.state(for: machine)
                    Button {
                        selection = machine
                    } label: {
                        HStack(spacing: RX.Space.s2) {
                            stateLabel(state)
                                .frame(width: 18)
                            Text(context.names[machine] ?? "Unknown server")
                                .font(.rxBody)
                                .foregroundStyle(.rxInk)
                                .lineLimit(1)
                            Spacer()
                            Text(duration(state))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.rxInkSecondary)
                        }
                        .padding(.horizontal, RX.Space.s2)
                        .frame(minHeight: 36)
                        .background(
                            RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                                .fill(selection == machine ? Color.rxAccent.opacity(0.15) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !state.isFinished {
                            Button(role: .destructive) {
                                context.stop(machine: machine)
                            } label: {
                                Label("Stop", systemImage: "stop.circle")
                            }
                        }
                    }
                }
            }
            .padding(RX.Space.s2)
        }
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    @ViewBuilder
    func stateLabel(_ state: BatchSnippetExecContext.MachineState) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle.dashed").foregroundStyle(.rxInkSecondary).accessibilityLabel("Waiting")
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark").foregroundStyle(.rxSuccess).accessibilityLabel("Done")
        case .failed: Image(systemName: "xmark").foregroundStyle(.rxDanger).accessibilityLabel("Failed")
        }
    }

    func duration(_ state: BatchSnippetExecContext.MachineState) -> String {
        let seconds: TimeInterval
        switch state {
        case .waiting: return ""
        case let .running(since): seconds = tick.timeIntervalSince(since)
        case let .done(duration), let .failed(duration): seconds = duration
        }
        return String(format: "%.1f s", max(0, seconds))
    }

    @ViewBuilder var output: some View {
        ZStack {
            ForEach(machines, id: \.self) { machine in
                BatchOutputView(machine: machine, isSelected: selection == machine)
                    .opacity(selection == machine ? 1 : 0)
                    .allowsHitTesting(selection == machine)
            }
        }
        .padding(RX.Space.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                .fill(Color.rxTerminalBackground)
        )
        .environmentObject(context)
    }
}

/// One server's output in a terminal surface.
private struct BatchOutputView: View {
    let machine: RDMachine.ID
    let isSelected: Bool
    @EnvironmentObject var context: BatchSnippetExecContext

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    @State private var terminalId = UUID()
    @State private var terminalView: CatusshTerminalView = {
        let view = CatusshTerminalView()
        view.setTerminalFontSize(with: CatusshStore.shared.terminalFontSize)
        return view
    }()

    @State private var drainedAfterFinish = false

    private func flushPending() {
        let incoming = context.requestBuffer(for: terminalId, machine: machine)
        if !incoming.isEmpty {
            terminalView.write(incoming)
        }
        if context.state(for: machine).isFinished {
            drainedAfterFinish = true
        }
    }

    var body: some View {
        terminalView
            .onAppear { flushPending() }
            .onChange(of: isSelected) { selected in
                if selected { flushPending() }
            }
            .onReceive(timer) { _ in
                guard isSelected || !drainedAfterFinish else { return }
                flushPending()
            }
    }
}
