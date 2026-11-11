//
//  MonitorView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/3.
//

import MachineStatus
import MachineStatusView
import CatusshModule
import SwiftUI

/// A server's monitor: facts, then the cards (one column on iPhone).
struct MonitorView: View {
    @ObservedObject var session: MonitorSession
    @EnvironmentObject var store: CatusshStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.inServerWorkspace) private var inServerWorkspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RX.Space.s4) {
                facts
                if session.phase == .connected, session.status.hasData {
                    MonitorDashboard(session: session)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                } else {
                    MonitorPlaceholder(session: session) {
                        session.reconnect()
                    }
                    .transition(.opacity)
                }
            }
            .padding(RX.Space.s4)
            .animation(.easeOut(duration: 0.3), value: session.phase == .connected && session.status.hasData)
        }
        .background(RXBackdrop().ignoresSafeArea())
        .navigationTitle(store.machineRedacted == .all ? "Monitor" : session.machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    TerminalManager.shared.begin(for: session.machine.id)
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                Menu {
                    Button {
                        FileTransferManager.shared.begin(for: session.machine.id)
                    } label: {
                        Label("Open File Transfer", systemImage: "arrow.up.arrow.down")
                    }
                    if session.machine.hasRemoteDesktop {
                        Button {
                            ServerActions.openDesktop(session.machine.id)
                        } label: {
                            Label("Open Remote Desktop", systemImage: "display")
                        }
                    }
                    if session.phase != .connected {
                        Button {
                            session.reconnect()
                        } label: {
                            Label("Reconnect", systemImage: "arrow.clockwise")
                        }
                    }
                    Button(role: .destructive) {
                        MonitorCenter.shared.end(session.id)
                        // On a server's page, the page stays for its other tools.
                        if !inServerWorkspace { dismiss() }
                    } label: {
                        Label("Close Monitor", systemImage: "xmark")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    var facts: some View {
        let system = session.status.system
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: RX.Space.s3) {
            fact("Hostname", system.hostname.isEmpty ? "—" : system.hostname)
            fact("System", system.releaseName.isEmpty ? "—" : system.releaseName)
            fact("Uptime", RXFormat.duration(system.uptimeSec))
            fact("Address", session.machine.remoteAddress, mono: true, redacted: store.machineRedacted != .none)
        }
    }

    func fact(_ label: String, _ value: String, mono: Bool = false, redacted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: RX.Space.s1) {
            CapsLabel(label)
            RedactableText(value, redacted: redacted)
                .font(mono ? .system(size: 14, weight: .medium, design: .monospaced) : .rxMetricMD)
                .foregroundStyle(.rxInk)
                .lineLimit(1)
        }
    }
}
