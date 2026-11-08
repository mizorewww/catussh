//
//  MainView.swift
//  catussh (macOS)
//

import CatusshModule
import MachineStatusView
import SwiftUI

struct MainView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var router = AppRouter.shared

    @State private var openLicenseAgreement = false
    @State private var settingsOpened = false

    var body: some View {
        NavigationSplitView(columnVisibility: $router.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: RX.sidebarWidth, max: 280)
        } detail: {
            ZStack {
                RXWindowBackground()
                    .ignoresSafeArea()
                if !router.route.isSession, router.route != .settings {
                    content
                        .id(router.route)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity
                        ))
                }
                if settingsOpened || router.route == .settings {
                    SettingsView(active: router.route == .settings)
                        .opacity(router.route == .settings ? 1 : 0)
                        .animation(router.route == .settings ? .easeOut(duration: 0.16) : nil, value: router.route == .settings)
                        .allowsHitTesting(router.route == .settings)
                        .accessibilityHidden(router.route != .settings)
                }
                SessionPages(route: router.route)
            }
            .onChange(of: router.route == .settings) { shown in
                if shown { settingsOpened = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.2), value: router.route.isSession ? nil : router.route)
            .rxClearToolbar()
        }
        .frame(minWidth: 940, minHeight: 600)
        .modifier(HiddenWindowTitle())
        .overlay {
            if store.globalProgressInPresent {
                ProgressHUD()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.globalProgressInPresent)
        .sheet(isPresented: $router.presentNewServer) {
            ServerEditorSheet(machine: nil)
                .environmentObject(CatusshStore.shared)
        }
        .sheet(isPresented: $openLicenseAgreement) {
            AgreementSheet()
        }
        .onAppear {
            if !store.licenseAgreed { openLicenseAgreement = true }
        }
    }

    @ViewBuilder var content: some View {
        switch router.route {
        case .home:
            HomeView()
        case .servers:
            ServersView()
        case .identities:
            IdentitiesView()
        case .snippets:
            SnippetsView()
        case .portForward:
            PortForwardView()
        case .desktops:
            RemoteDesktopsView()
        case .settings, .terminal, .monitor, .transfer, .editor, .desktop:
            EmptyView()
        }
    }
}

private struct SessionPages: View {
    let route: Route
    @ObservedObject var terminals = TerminalManager.shared
    @ObservedObject var transfers = FileTransferManager.shared
    @ObservedObject var editors = EditorCenter.shared
    @ObservedObject var monitors = MonitorCenter.shared
    @ObservedObject var desktops = RemoteDesktopManager.shared

    var body: some View {
        ZStack {
            ForEach(terminals.sessionContexts) { context in
                TerminalPage(context: context)
                    .sessionPage(active: route == .terminal(context.id))
            }
            ForEach(transfers.transfers) { context in
                FileTransferPage(context: context)
                    .sessionPage(active: route == .transfer(context.id))
            }
            ForEach(editors.workspaces) { workspace in
                EditorPage(workspace: workspace)
                    .sessionPage(active: route == .editor(workspace.id))
            }
            ForEach(monitors.sessions) { session in
                MonitorPage(session: session)
                    .sessionPage(active: route == .monitor(session.id))
            }
            ForEach(desktops.sessions) { session in
                RemoteDesktopPage(session: session)
                    .sessionPage(active: route == .desktop(session.id))
            }
        }
    }
}

private extension View {
    func sessionPage(active: Bool) -> some View {
        opacity(active ? 1 : 0)
            .animation(active ? .easeOut(duration: 0.16) : nil, value: active)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
            .environment(\.isActivePage, active)
    }
}

private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .navigationTitle("catussh")
                .toolbar(removing: .title)
        } else {
            content.navigationTitle("catussh")
        }
    }
}
