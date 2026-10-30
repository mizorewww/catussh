//
//  CatusshApp.swift
//  Shared
//
//  Created by Lakr Aream on 2022/2/8.
//

import CodeEditorUI
import Combine
import CatusshModule
import os
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
    let session: RemoteDesktopSession
    /// Not the session itself: it changes with every frame, and each change
    /// rebuilds the whole menu bar, which kept the main thread too busy to
    /// finish quitting.
    @StateObject private var state: DesktopMenuState

    init(session: RemoteDesktopSession) {
        self.session = session
        _state = StateObject(wrappedValue: DesktopMenuState(session))
    }

    var body: some View {
        let connected = state.connected
        Button("Send Ctrl+Alt+Delete") { session.sendKeys(RemoteDesktopSpecialKeys.ctrlAltDelete) }
            .disabled(!connected || state.viewOnly)
        Button("Paste Clipboard to Remote") {
            if let text = UIPasteboard.general.string, !text.isEmpty { session.pushClipboard(text) }
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!connected)
        Button("Copy Remote Clipboard") { UIPasteboard.general.string = session.remoteClipboard }
            .disabled(!state.hasRemoteClipboard)
        Divider()
        Toggle("View Only", isOn: Binding(get: { state.viewOnly }, set: { session.viewOnly = $0 }))
        Button("Refresh Screen") { session.refresh() }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!connected)
        Divider()
        if state.ended {
            Button("Reconnect") { session.connect() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        } else {
            Button("Disconnect") { session.disconnect() }
        }
    }
}

/// The few things the Desktop menu shows, published only when one changes.
@MainActor
private final class DesktopMenuState: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var ended = false
    @Published private(set) var viewOnly = false
    @Published private(set) var hasRemoteClipboard = false
    private var watchers: Set<AnyCancellable> = []

    init(_ session: RemoteDesktopSession) {
        session.$phase
            .map { $0 == .connected }
            .removeDuplicates()
            .sink { [weak self] in self?.connected = $0 }
            .store(in: &watchers)
        session.$phase
            .map { $0.isTerminal || $0 == .idle }
            .removeDuplicates()
            .sink { [weak self] in self?.ended = $0 }
            .store(in: &watchers)
        session.$viewOnly
            .removeDuplicates()
            .sink { [weak self] in self?.viewOnly = $0 }
            .store(in: &watchers)
        session.$remoteClipboard
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] in self?.hasRemoteClipboard = $0 }
            .store(in: &watchers)
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
            // "servers" or "desktops": that page in front, for screenshots.
            if let page = ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_ROUTE"] {
                let routes: [String: Route] = ["servers": .servers, "desktops": .desktops, "home": .home]
                if let route = routes[page] { AppRouter.shared.route = route }
            }
            // A UU session file (in the debug container) to sign in with, and
            // "terminal:<alias>" or "desktop:<alias>" to open on that device.
            if let path = ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_UU_SESSION"] {
                let open = ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_OPEN"]?.split(separator: ":", maxSplits: 1).map(String.init)
                Task { @MainActor in
                    await UURemoteAccountStore.shared.adoptSessionForPreview(from: URL(fileURLWithPath: path))
                    guard let open, open.count == 2,
                          let machine = CatusshStore.shared.machineGroup.machines.first(where: { machine in
                              machine.isUURemoteDevice && machine.name == open[1]
                                  && UURemoteAccountStore.shared.devices.contains { $0.deviceID == machine.uuDeviceID }
                          })
                    else { return }
                    if open[0] == "terminal" { AppRouter.shared.openTerminal(machine: machine.id) }
                    if open[0] == "desktop" { AppRouter.shared.openDesktop(machine: machine.id) }
                }
            }
            if ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_UU_SIGNIN"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { FolderActions.linkUURemote() }
            }
            // Sample folders: an empty local one and a UU Remote one with two
            // devices. Saved in the debug build's own container.
            if ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_FOLDERS"] != nil {
                let store = CatusshStore.shared
                if store.folder(named: "Lab") == nil { store.createFolder(named: "Lab") }
                let folder = store.folderGroup.folders.first { $0.isLinked }
                    ?? store.createFolder(named: "UU Remote", source: .uuRemote(userID: "preview"))
                var devices: [UUDeviceInfo] = []
                for (id, alias, platform) in [("preview-mac", "Macbook_Pro_M2", 4), ("preview-pc", "Studio PC", 1)] {
                    var device = UUDeviceInfo()
                    device.deviceID = id
                    device.alias = alias
                    device.platform = platform
                    devices.append(device)
                }
                var group = store.machineGroup
                UURemoteFolderSync.apply(devices: devices, folder: folder.name, to: &group)
                store.machineGroup = group
            }
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
    /// When it was asked: with no window to hang it on, the alert opens a
    /// run-loop turn later, and until then it is neither a sheet nor modal.
    @MainActor private var quitAskedAt = Date.distantPast

    private static let quitLog = Logger(subsystem: "me.mizorewww.rayon", category: "quit")

    /// Asked when the app is about to quit. With terminals open or unsaved
    /// text, the answer is no for now, and the question goes to the user.
    @MainActor func mayTerminate() -> Bool {
        let allowed = answerTermination()
        if allowed {
            // From here AppKit hides the windows on its way out; the watcher
            // must not take that for "only the menu bar is left" and switch
            // the activation policy, which UIKit reads as a relaunch to the
            // foreground: the quit then stalled until its watchdog killed
            // the app (seconds; with menu bar items, possibly never).
            terminating = true
            // A quit cancelled further on gives the watcher back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.terminating = false }
        }
        return allowed
    }

    /// The app is on its way out; the window watcher stands still.
    @MainActor private var terminating = false

    @MainActor private func answerTermination() -> Bool {
        // The question was answered; this is the quit that follows it.
        if quitConfirmed { return true }
        if quitAsked {
            // Still on screen: this quit waits for its answer. Gone without
            // one (its window closed under it): ask again rather than refuse
            // every quit from now on.
            if Mac.bridge?.isShowingSheet() == true || Mac.bridge?.hasModalWindow() == true
                || Date().timeIntervalSince(quitAskedAt) < 2
            {
                Self.quitLog.info("quit waits for the open question")
                return false
            }
            Self.quitLog.error("quit question lost without an answer; asking again")
            quitAsked = false
        }
        let terminals = !TerminalManager.shared.sessionContexts.isEmpty
        // Unsaved text is always asked about, whatever the setting.
        let unsaved = EditorCenter.shared.workspaces.contains(where: \.hasUnsavedChanges)
        Self.quitLog.info("quit requested: terminals \(terminals), unsaved \(unsaved)")
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
        quitAskedAt = Date()
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
        guard let bridge = Mac.bridge, !terminating else { return }
        bridge.setAccessory(!bridge.hasVisibleWindow() && MenubarTool.shared.hasCat)
    }
}
