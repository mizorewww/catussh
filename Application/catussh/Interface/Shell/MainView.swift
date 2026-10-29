//
//  MainView.swift
//  catussh (macOS)
//
//  The main window: a native sidebar (Liquid Glass on macOS 26) over a translucent
//  window, and the content column.
//

import MachineStatusView
import CatusshModule
import SwiftUI
import UIKit

struct MainView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var router = AppRouter.shared

    @State private var openLicenseAgreement = false
    /// Unknown until the view is in a window. SwiftUI's WindowGroup puts a main
    /// window in a menu bar popover's scene too, hidden; it must stay empty, or
    /// its terminal pages take the terminals from the real window.
    @State private var inPopoverScene: Bool?
    /// Settings is built when it is first opened and kept from then on: its
    /// categories are many rows each, and coming back shows what is there.
    @State private var settingsOpened = false

    var body: some View {
        Group {
            if inPopoverScene == false {
                window
            } else {
                Color.clear
            }
        }
        .background(SceneProbe { inPopoverScene = $0 })
    }

    private var window: some View {
        NavigationSplitView(columnVisibility: $router.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: RX.sidebarWidth, max: 280)
        } detail: {
            // Pages cross-fade with a slight rise, so the eye follows the change
            // of place instead of seeing the content column jump.
            ZStack {
                RXWindowBackground()
                    .ignoresSafeArea()
                // Places (Home, Servers, Settings…) cross-fade with a slight rise,
                // so the eye follows the change of place.
                if !router.route.isSession, router.route != .settings {
                    content
                        .id(router.route)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 6)),
                            removal: .opacity
                        ))
                }
                if settingsOpened || router.route == .settings {
                    // Told directly, not through the environment: a change of
                    // environment reaches every row of every category.
                    SettingsView(active: router.route == .settings)
                        .opacity(router.route == .settings ? 1 : 0)
                        .animation(router.route == .settings ? .easeOut(duration: 0.16) : nil, value: router.route == .settings)
                        .allowsHitTesting(router.route == .settings)
                        .accessibilityHidden(router.route != .settings)
                }
                SessionPages(route: router.route)
            }
            .onChange(of: router.route == .settings) { shown in
                // Before macOS 26 its toolbar and search field cannot be taken
                // out of the window while it is kept, so there it is not kept.
                if shown, #available(iOS 26.0, *) { settingsOpened = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.2), value: router.route.isSession ? nil : router.route)
            // Set here, outside the page transition, so the toolbar never falls
            // back to its opaque background while one page fades into another.
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
            onMainThread(delay: 0.5) {
                if !store.licenseAgreed { openLicenseAgreement = true }
            }
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

/// Every open terminal, file browser, editor and monitor stays mounted; the route only
/// decides which one is visible. Switching between a server's Terminal, Files
/// and Monitor (or between servers) is then a change of visibility, with no
/// page or terminal surface rebuilt and scroll positions kept.
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
            // The page coming in fades up quickly; the one going out leaves at
            // once, so two layouts never mix on screen.
            .animation(active ? .easeOut(duration: 0.16) : nil, value: active)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
            .environment(\.isActivePage, active)
    }
}

/// Reports, once in a window, whether that window belongs to a menu bar
/// popover's scene.
private struct SceneProbe: UIViewRepresentable {
    let report: (Bool) -> Void

    final class Probe: UIView {
        var report: ((Bool) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            // SwiftUI's delegate stands in front of the one the scene was
            // configured with; the configuration says whose scene it is.
            let inPopover = scene.session.configuration.delegateClass == TraySceneDelegate.self
                || TraySceneDelegate.owns(scene.session)
            DispatchQueue.main.async { [report] in report?(inPopover) }
        }
    }

    func makeUIView(context _: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.report = report
        return probe
    }

    func updateUIView(_: Probe, context _: Context) {}
}

/// The window toolbar holds page controls only; the page title is in the content.
private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.toolbar(removing: .title)
        } else {
            content.navigationTitle("")
        }
    }
}
