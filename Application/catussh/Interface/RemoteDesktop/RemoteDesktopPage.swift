//
//  RemoteDesktopPage.swift
//  catussh (macOS)
//
//  A server's remote desktop (a session in the sidebar): the Terminal · Files
//  · Monitor · Desktop switcher, the page header, then the interactive stage
//  (canvas + control bar) from CatusshModule.
//

import CatusshModule
import SwiftUI

struct RemoteDesktopPage: View {
    @ObservedObject var session: RemoteDesktopSession
    @EnvironmentObject var store: CatusshStore

    var body: some View {
        PageScaffold {
        } trailing: {
            ToolbarAction("Close Desktop", systemImage: "xmark") {
                RemoteDesktopManager.shared.end(session.id)
            }
        } header: {
            VStack(alignment: .leading, spacing: RX.Space.s2) {
                PageTitle(store.machineRedacted == .all ? "Server" : session.machine.name)
                Text(subtitle)
                    .font(.rxHelp)
                    .foregroundStyle(.rxInkSecondary)
            }
        } content: {
            RemoteDesktopStageView(session: session) {
                RemoteDesktopManager.shared.end(session.id)
            }
            .clipShape(RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                    .strokeBorder(Color.rxHairline)
            )
        }
        .serverToolSwitcher(machine: session.machine.id, current: .desktop)
    }

    private var subtitle: String {
        var parts = [session.protocolType.displayName]
        switch session.protocolType {
        case .vnc:
            parts.append(session.machine.remoteAddress + ":" + session.machine.vncPort)
        case .uuRemote:
            let name = session.machine.uuDeviceAlias.isEmpty
                ? session.machine.uuDeviceID
                : session.machine.uuDeviceAlias
            if !name.isEmpty { parts.append(name) }
        case .none:
            break
        }
        return parts.joined(separator: " · ")
    }
}
