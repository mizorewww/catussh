//
//  CatusshApp.swift
//  catussh (macOS)
//

import AppKit
import Combine
import CatusshModule
import CatusshTerminal
import os
import SwiftUI

@main
struct CatusshApp: App {
    @StateObject private var store = CatusshStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        #if DEBUG
            NSLog(CommandLine.arguments.joined(separator: "\n"))
        #endif
        _ = CatusshStore.shared
        CloudSync.shared.start()

        PortForwardBackend.shared.onError = { UIBridge.presentError(with: $0) }
        FileTransferInterface.uiHandler = MacFileTransferUIHandler()

        NSLog("static main completed")
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CatusshCommands()
        }
    }
}

struct CatusshCommands: Commands {
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var terminals = TerminalManager.shared

    private var terminal: TerminalManager.Context? { router.terminalInFront }
    @ObservedObject private var desktops = RemoteDesktopManager.shared

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { AppRouter.shared.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("New Server…") { AppRouter.shared.presentNewServer = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Terminal") { AppRouter.shared.newTerminal() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Local Terminal") { AppRouter.shared.openLocalTerminal(another: true) }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button("Open Terminals…") { AppRouter.shared.openTerminals() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
        if router.route.isSession {
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { AppRouter.shared.closeTabInFront() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
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

    private func place(_ title: String, _ route: Route, key: KeyEquivalent) -> some View {
        Button(title) { AppRouter.shared.route = route }
            .keyboardShortcut(terminal == nil ? KeyboardShortcut(key, modifiers: .command) : nil)
    }
}

private struct DesktopCommands: View {
    let session: RemoteDesktopSession
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
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                session.pushClipboard(text)
            }
        }
        .keyboardShortcut("v", modifiers: [.command, .shift])
        .disabled(!connected)
        Button("Copy Remote Clipboard") {
            UIBridge.sendPasteboard(str: session.remoteClipboard)
        }
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

enum MainWindow {
    static let minimumSize = CGSize(width: 940, height: 600)

    @MainActor static var ordinaryWindows: [NSWindow] {
        NSApp.windows.filter { window in
            window.canBecomeMain && !window.className.contains("NSPopover") && !window.className.contains("NSStatusBar")
        }
    }

    @MainActor static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = ordinaryWindows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static var shared: AppDelegate!
    private var shortcutMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_: Notification) {
        AppearancePreference.applyStored()
        // The appearance may come from another device, through iCloud.
        windowObservers.append(
            NotificationCenter.default.addObserver(forName: CloudSync.settingsDidChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppearancePreference.applyStored() }
            }
        )
        installShortcutMonitor()
        installWindowPolicyObservers()
        MenubarTool.shared.restore()
        updateActivationPolicy()

        #if DEBUG
            if ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_TERMINAL"] != nil,
               let command = SSHCommandReader(command: "ssh demo@203.0.113.10")
            {
                AppRouter.shared.openTerminal(command: command)
                AppRouter.shared.route = .terminal(TerminalManager.shared.sessionContexts.last!.id)
            }
            if let categories = ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_SETTINGS"]?.split(separator: ",").map(String.init) {
                for (index, category) in categories.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 2) {
                        if category == "@terminal", let session = TerminalManager.shared.sessionContexts.last {
                            AppRouter.shared.route = .terminal(session.id)
                        } else {
                            AppRouter.shared.openSettings(category)
                        }
                    }
                }
            }
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
            if let page = ProcessInfo.processInfo.environment["CATUSSH_PREVIEW_ROUTE"] {
                let routes: [String: Route] = ["servers": .servers, "desktops": .desktops, "home": .home]
                if let route = routes[page] { AppRouter.shared.route = route }
            }
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
    }

    private func installWindowPolicyObservers() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            windowObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.updateActivationPolicy()
                    }
                }
            )
        }
    }

    func updateActivationPolicy() {
        guard !terminating else { return }
        let hasVisibleWindow = MainWindow.ordinaryWindows.contains { $0.isVisible || $0.isMiniaturized }
        let accessory = !hasVisibleWindow && MenubarTool.shared.hasCat
        let policy: NSApplication.ActivationPolicy = accessory ? .accessory : .regular
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    private func installShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleShortcut(event) else { return event }
            return nil
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              NSApp.modalWindow == nil
        else { return false }
        let key: String
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (12, _), (_, "q"): key = "q"
        case (13, _), (_, "w"): key = "w"
        case (17, _), (_, "t"): key = "t"
        default: return false
        }
        switch key {
        case "q":
            NSApp.terminate(nil)
            return true
        case "t":
            if CatusshUtil.isShowingSheetOrModal { return true }
            let window = event.window ?? NSApp.keyWindow
            guard let window, MainWindow.ordinaryWindows.contains(window) else { return false }
            if event.isARepeat { return true }
            AppRouter.shared.newTerminal()
            return true
        case "w":
            if CatusshUtil.isShowingSheetOrModal { return true }
            let window = event.window ?? NSApp.keyWindow
            guard let window, MainWindow.ordinaryWindows.contains(window) else { return false }
            if event.isARepeat { return true }
            AppRouter.shared.closeTabInFront()
            return true
        default:
            return false
        }
    }

    private var quitConfirmed = false
    private var quitAsked = false
    private var terminating = false
    private static let quitLog = Logger(subsystem: "me.mizorewww.rayon", category: "quit")

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        if quitConfirmed {
            terminating = true
            return .terminateNow
        }
        if quitAsked, CatusshUtil.isShowingSheetOrModal {
            return .terminateCancel
        }
        quitAsked = false

        let terminals = !TerminalManager.shared.sessionContexts.isEmpty
        let kept = TerminalManager.shared.sessionContexts.filter(\.machine.isUURemoteDevice).count
        let terminalConsequence = switch kept {
        case 0: "Open terminal sessions will be closed."
        case TerminalManager.shared.sessionContexts.count: "UU Remote sessions keep running on their devices, to resume next time."
        default: "SSH sessions will be closed; UU Remote sessions keep running on their devices, to resume next time."
        }
        let unsaved = EditorCenter.shared.workspaces.contains(where: \.hasUnsavedChanges)
        Self.quitLog.info("quit requested: terminals \(terminals), unsaved \(unsaved)")
        guard terminals || unsaved else {
            terminating = true
            return .terminateNow
        }
        if CatusshStore.shared.disableConformation, !unsaved {
            terminating = true
            TerminalManager.shared.closeAll()
            return .terminateNow
        }
        let consequences = [
            unsaved ? "Unsaved changes in the editor will be lost." : nil,
            terminals ? terminalConsequence : nil,
        ]
        quitAsked = true
        UIBridge.requiresConfirmation(
            message: "Quit catussh?",
            informative: consequences.compactMap { $0 }.joined(separator: " "),
            confirmTitle: unsaved ? "Discard Changes and Quit" : "Quit",
            destructive: true,
            always: unsaved
        ) { confirmed in
            MainActor.assumeIsolated {
                self.quitAsked = false
                guard confirmed else { return }
                self.quitConfirmed = true
                self.terminating = true
                TerminalManager.shared.closeAll()
                NSApp.terminate(nil)
            }
        }
        return .terminateCancel
    }
}
