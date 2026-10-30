//
//  RemoteDesktopPage.swift
//  catussh (macOS)
//
//  A server's remote desktop (a session in the sidebar): the tool switcher,
//  then the interactive stage (canvas + control bar) from CatusshModule,
//  filling the page.
//

import CatusshModule
import SwiftUI

struct RemoteDesktopPage: View {
    @ObservedObject var session: RemoteDesktopSession
    @EnvironmentObject var store: CatusshStore

    /// Like a terminal: the remote screen takes the whole page. Its name is
    /// in the sidebar and the tool switcher; its state on the stage's bar.
    var body: some View {
        PageScaffold(scrolls: false) {
        } trailing: {
            ToolbarAction("Close Desktop", systemImage: "xmark") {
                RemoteDesktopManager.shared.end(session.id)
            }
        } content: {
            // Closing is the toolbar's Close Desktop; no second one on the bar.
            RemoteDesktopStageView(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RX.Radius.md, style: .continuous)
                    .strokeBorder(Color.rxHairline)
            )
            .help(subtitle)
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
