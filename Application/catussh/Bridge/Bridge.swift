//
//  Bridge.swift
//  MacBridge
//
//  AppKit for the Catalyst app: loaded from Contents/PlugIns at launch. SwiftUI
//  is out of reach here (a Catalyst process carries the iOS one), so this is
//  plain AppKit, and views with content come from the app as UIKit windows.
//

import AppKit
import ObjectiveC
import os

@objc(Bridge) final class Bridge: NSObject, MacBridging {
    var statusItems: [String: StatusItem] = [:]
    var mayTerminate: (() -> Bool)?
    var openApp: (() -> Void)?
    /// Windows that existed before a popover's window was asked for.
    var windowsBeforePopover: Set<ObjectIdentifier>?
    var updateObserver: NSObjectProtocol?
    var closeShortcut: (() -> Bool)?
    var shortcutMonitor: Any?

    override required init() {
        super.init()
    }

    // MARK: Application

    func setAppearance(_ name: String?) {
        switch name {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
        for item in statusItems.values { item.popover?.appearance = NSApp.appearance }
    }

    func setTerminationGuard(_ mayTerminate: @escaping () -> Bool) {
        let install = self.mayTerminate == nil
        self.mayTerminate = mayTerminate
        if install { installTerminationGuard() }
    }

    /// UIKit owns the application delegate; its answer to "should terminate"
    /// is wrapped rather than replaced.
    static let quitLog = Logger(subsystem: "me.mizorewww.rayon", category: "quit")

    private func installTerminationGuard() {
        guard let delegate = NSApp.delegate else {
            Bridge.quitLog.error("no application delegate yet; the termination guard is not installed")
            return
        }
        Bridge.quitLog.info("termination guard on \(String(describing: type(of: delegate)), privacy: .public)")
        let selector = #selector(NSApplicationDelegate.applicationShouldTerminate(_:))
        let cls: AnyClass = type(of: delegate)
        typealias Original = @convention(c) (AnyObject, Selector, NSApplication) -> NSApplication.TerminateReply
        let original = class_getInstanceMethod(cls, selector).map {
            unsafeBitCast(method_getImplementation($0), to: Original.self)
        }
        let block: @convention(block) (AnyObject, NSApplication) -> NSApplication.TerminateReply = { [weak self] receiver, app in
            if let mayTerminate = self?.mayTerminate, !mayTerminate() {
                Bridge.quitLog.info("should terminate: no, the app asks first")
                return .terminateCancel
            }
            let reply = original?(receiver, selector, app) ?? .terminateNow
            Bridge.quitLog.info("should terminate: UIKit answers \(reply.rawValue)")
            return reply
        }
        let implementation = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, implementation, "Q@:@"),
           let method = class_getInstanceMethod(cls, selector)
        {
            method_setImplementation(method, implementation)
        }
    }

    func terminate() {
        NSApp.terminate(nil)
    }

    func setCloseShortcutHandler(_ handler: @escaping () -> Bool) {
        closeShortcut = handler
        guard shortcutMonitor == nil else { return }
        // A local monitor sees the key before the menu, the window and UIKit
        // do: the terminal surface takes every key press it is sent, ⌘W and
        // ⌘Q included, and the menu's Close shuts the only window.
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleShortcut(event) else { return event }
            return nil
        }
    }

    /// ⌘Q quits and ⌘W closes the tab in front of a main window. Anything
    /// modal (an alert, a panel) keeps its own keys; while a sheet is up ⌘W
    /// is dropped, so a second close question is never stacked on the first.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              NSApp.modalWindow == nil
        else { return false }
        // By key position as well, so a non-Latin layout still has them.
        let key: String
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (12, _), (_, "q"): key = "q"
        case (13, _), (_, "w"): key = "w"
        default: return false
        }
        switch key {
        case "q":
            // Never dropped: the termination guard knows whether its own
            // question is still up, and a sheet left behind by anything else
            // must not keep catussh from quitting.
            NSApp.terminate(nil)
            return true
        case "w":
            if isShowingSheet() { return true }
            let window = event.window ?? NSApp.keyWindow
            guard let window, ordinaryWindows.contains(window) else { return false }
            // Held down, ⌘W would close and reopen the last tab over and over.
            if event.isARepeat { return true }
            return closeShortcut?() ?? false
        default:
            return false
        }
    }

    func hasModalWindow() -> Bool {
        NSApp.modalWindow != nil
    }

    func isShowingSheet() -> Bool {
        ordinaryWindows.contains { $0.attachedSheet != nil }
    }

    func activate(window uiWindow: AnyObject?) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let window = uiWindow.flatMap(nsWindow(for:)) ?? ordinaryWindows.first
        window?.makeKeyAndOrderFront(nil)
    }

    func hasVisibleWindow() -> Bool {
        // A minimized window is not visible, but it is still open: catussh
        // must keep its Dock icon to bring it back, and its menu to quit.
        ordinaryWindows.contains { $0.isVisible || $0.isMiniaturized }
    }

    func setAccessory(_ accessory: Bool) {
        let policy: NSApplication.ActivationPolicy = accessory ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }
}
