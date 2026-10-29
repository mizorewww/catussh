//
//  CatusshApp.swift
//  Shared
//
//  Created by Lakr Aream on 2022/2/8.
//

import CodeEditorUI
import CatusshModule
import CatusshTerminal
import SwiftUI
import UIKit

@main
struct CatusshApp: App {
    @StateObject private var store = CatusshStore.shared

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        #if DEBUG
            NSLog(CommandLine.arguments.joined(separator: "\n"))
        #endif
        // Before the store: it reads the master key as it loads.
        Mac.installLegacyKeyStore()
        _ = CatusshStore.shared
        CloudSync.shared.start()

        // Shared file-transfer core lives in CatusshModule; register the
        // platform UI handler it delegates to.
        FileTransferInterface.uiHandler = MacFileTransferUIHandler()

        // The window material is AppKit's; the backdrop view reports the
        // windows it is in.
        RXWindowBackground.install = { window in MainWindow.prepare(window) }

        NSLog("static main completed")
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
        }
        .commands {
            SidebarCommands()
            CatusshCommands()
        }
    }
}

/// Menu commands: New Server, Settings (Settings is a sidebar destination), navigation.
/// On a session, ⌘W closes the tab in front instead of the window, and ⌘1–⌘9
/// pick a tab (⌘9 the last, as in Safari) instead of a sidebar place.
struct CatusshCommands: Commands {
    @ObservedObject private var router = AppRouter.shared
    /// For the tabs: terminals open and close without the route changing.
    @ObservedObject private var terminals = TerminalManager.shared

    private var terminal: TerminalManager.Context? { router.terminalInFront }
    /// For the Desktop menu: sessions open and close without the route changing.
    @ObservedObject private var desktops = RemoteDesktopManager.shared

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { AppRouter.shared.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("New Server…") { AppRouter.shared.presentNewServer = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Terminals…") { AppRouter.shared.openTerminals() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        // Takes the place of the window's Close and Close All while a session
        // is in front. The key itself is caught by MacBridge before the menu
        // (see AppDelegate), so this is the item to click.
        if router.route.isSession {
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { AppRouter.shared.closeTabInFront() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
        #if targetEnvironment(macCatalyst)
            CommandGroup(after: .textEditing) {
                Button("Find") { NotificationCenter.default.post(name: .rxFocusToolbarSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        #endif
        if let desktop = router.desktopInFront {
            CommandMenu("Desktop") {
                DesktopCommands(session: desktop)
            }
        }
        CommandGroup(after: .sidebar) {
            place("Home", .home, key: "1")
            place("Servers", .servers, key: "2")
            place("Identities", .identities, key: "3")
            place("Snippets", .snippets, key: "4")
            place("Port Forward", .portForward, key: "5")
            place("Remote Desktop", .desktops, key: "6")
            if let terminal {
                Divider()
                let tabs = terminal.tabSiblings
                ForEach(Array(tabs.prefix(8).enumerated()), id: \.element.id) { index, tab in
                    Button("Tab \(index + 1)") { AppRouter.shared.route = .terminal(tab.id) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                if let last = tabs.last {
                    Button("Last Tab") { AppRouter.shared.route = .terminal(last.id) }
                        .keyboardShortcut("9", modifiers: .command)
                }
            }
            Divider()
        }
    }

    /// A sidebar place; its ⌘ number goes to the terminal's tabs while one is in front.
    private func place(_ title: String, _ route: Route, key: KeyEquivalent) -> some View {
        Button(title) { AppRouter.shared.route = route }
            .keyboardShortcut(terminal == nil ? KeyboardShortcut(key, modifiers: .command) : nil)
    }
}

/// The Desktop menu, while a remote desktop is in front: the stage's controls
/// with keys to them.
private struct DesktopCommands: View {
    @ObservedObject var session: RemoteDesktopSession

    var body: some View {
        let connected = session.phase == .connected
        Button("Send Ctrl+Alt+Delete") { session.sendKeys(RemoteDesktopSpecialKeys.ctrlAltDelete) }
            .disabled(!connected || session.viewOnly)
        Button("Paste Clipboard to Remote") {
            if let text = UIPasteboard.general.string, !text.isEmpty { session.pushClipboard(text) }
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!connected)
        Button("Copy Remote Clipboard") { UIPasteboard.general.string = session.remoteClipboard }
            .disabled(session.remoteClipboard.isEmpty)
        Divider()
        Toggle("View Only", isOn: $session.viewOnly)
        Button("Refresh Screen") { session.refresh() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!connected)
        Divider()
        if session.phase.isTerminal || session.phase == .idle {
            Button("Reconnect") { session.connect() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        } else {
            Button("Disconnect") { session.disconnect() }
        }
    }
}

/// What a main window needs from UIKit and AppKit that SwiftUI does not offer
/// on Mac Catalyst.
enum MainWindow {
    static let minimumSize = CGSize(width: 940, height: 600)

    @MainActor static func prepare(_ window: UIWindow) {
        if let scene = window.windowScene, !(scene.delegate is TraySceneDelegate) {
            // The toolbar holds page controls only; the page title is in the content.
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbarStyle = .unified
            scene.sizeRestrictions?.minimumSize = minimumSize
        }
        Mac.bridge?.installBackdrop(for: window)
    }

    /// Brings the main window forward, reopening it if it was closed.
    @MainActor static func show() {
        if let scene = CatusshUtil.mainScene() {
            Mac.bridge?.activate(window: scene.windows.first)
            return
        }
        Mac.bridge?.activate(window: nil)
        let closed = UIApplication.shared.openSessions.first { $0.scene == nil && !TraySceneDelegate.owns($0) }
        if #available(iOS 17.0, *) {
            let request = closed.map { UISceneSessionActivationRequest(session: $0) }
                ?? UISceneSessionActivationRequest(role: .windowApplication)
            UIApplication.shared.activateSceneSession(for: request)
        } else {
            UIApplication.shared.requestSceneSessionActivation(closed, userActivity: nil, options: nil)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set once at launch on the main thread; read there ever after.
    @MainActor private(set) static var shared: AppDelegate!

    override init() {
        super.init()
        debugPrint("\(self) \(#function)")
        assert(AppDelegate.shared == nil, "duplicated init of AppDelegate")
        AppDelegate.shared = self

        let timer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(windowStatusWatcher),
            userInfo: nil,
            repeats: true
        )
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
    }

    func application(_: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppearancePreference.applyStored()
        UITextField.drawPlaceholdersAsAppKit()
        Mac.bridge?.setTerminationGuard { AppDelegate.shared.mayTerminate() }
        Mac.bridge?.setOpenAppHandler { MainActor.assumeIsolated { MainWindow.show() } }
        // ⌘W closes the tab in front and never the main window: with one
        // window, closing it looks like the app quitting.
        Mac.bridge?.setCloseShortcutHandler {
            MainActor.assumeIsolated { AppRouter.shared.closeTabInFront() }
            return true
        }
        TraySceneDelegate.discardLeftovers()
        MenubarTool.shared.restore()
        #if DEBUG
            if ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_TERMINAL"] != nil,
               let command = SSHCommandReader(command: "ssh demo@203.0.113.10")
            {
                AppRouter.shared.openTerminal(command: command)
                AppRouter.shared.route = .terminal(TerminalManager.shared.sessionContexts.last!.id)
            }
            // "colors" opens Settings there; "general,colors" goes on to the second.
            if let categories = ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_SETTINGS"]?.split(separator: ",").map(String.init) {
                for (index, category) in categories.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 2) {
                        // "@terminal" leaves Settings for the preview terminal.
                        if category == "@terminal", let session = TerminalManager.shared.sessionContexts.last {
                            AppRouter.shared.route = .terminal(session.id)
                        } else {
                            AppRouter.shared.openSettings(category)
                        }
                    }
                }
            }
            // "key=value" makes that edit six seconds in and takes it back ten later.
            if let pair = ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_EDIT"]?.split(separator: "=", maxSplits: 1).map(String.init), pair.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    let old = ConfigBenchmark.value(pair[0])
                    ConfigBenchmark.edit(pair[0], pair[1])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { ConfigBenchmark.edit(pair[0], old) }
                }
            }
            if ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_MENUBAR"] != nil {
                MenubarTool.shared.showPreview()
            }
            Bench.runIfRequested()
            if ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_EDITOR"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppRouter.shared.showEditorPreview() }
            }
        #endif
        return true
    }

    func application(
        _: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if TraySceneDelegate.claims(session, options: options) {
            configuration.delegateClass = TraySceneDelegate.self
        }
        return configuration
    }

    /// Set once the user agreed to quit, so the quit that follows goes through.
    @MainActor private var quitConfirmed = false
    /// The quit question is on screen; another quit waits for its answer.
    @MainActor private var quitAsked = false

    /// Asked when the app is about to quit. With terminals open or unsaved
    /// text, the answer is no for now, and the question goes to the user.
    @MainActor func mayTerminate() -> Bool {
        // The question was answered; this is the quit that follows it.
        if quitConfirmed { return true }
        if quitAsked { return false }
        let terminals = !TerminalManager.shared.sessionContexts.isEmpty
        // Unsaved text is always asked about, whatever the setting.
        let unsaved = EditorCenter.shared.workspaces.contains(where: \.hasUnsavedChanges)
        guard terminals || unsaved else { return true }
        if CatusshStore.shared.disableConformation, !unsaved {
            TerminalManager.shared.closeAll()
            return true
        }
        let consequences = [
            unsaved ? "Unsaved changes in the editor will be lost." : nil,
            terminals ? "Open terminal sessions will be closed." : nil,
        ]
        quitAsked = true
        UIBridge.requiresConfirmation(
            message: "Quit catussh?",
            informative: consequences.compactMap { $0 }.joined(separator: " "),
            confirmTitle: unsaved ? "Discard Changes and Quit" : "Quit",
            destructive: true,
            always: unsaved
        ) { confirmed in
            MainActor.assumeIsolated { self.quitAsked = false }
            guard confirmed else { return }
            MainActor.assumeIsolated { self.quitConfirmed = true }
            TerminalManager.shared.closeAll()
            Mac.bridge?.terminate()
        }
        return false
    }

    /// With every window closed and a server in the menu bar, catussh leaves the
    /// Dock and stays in the menu bar.
    @objc
    func windowStatusWatcher() {
        guard let bridge = Mac.bridge else { return }
        bridge.setAccessory(!bridge.hasVisibleWindow() && MenubarTool.shared.hasCat)
    }
}
