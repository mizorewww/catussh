//
//  MacBridging.swift
//  catussh
//
//  What the Mac Catalyst app asks of AppKit. MacBridge.bundle implements it; the
//  app loads the bundle at launch and talks to it through this protocol only.
//  Everything here is called on the main thread.
//

import Foundation

/// The result of looking for the master key in the login keychain.
@objc(MacLegacyKeyStatus) public enum MacLegacyKeyStatus: Int {
    case found
    /// No such item.
    case absent
    /// The item may exist, but was not handed over.
    case unavailable
}

@objc(MacBridging) public protocol MacBridging: NSObjectProtocol {
    init()

    // MARK: Keychain

    /// Reads a generic password from the login keychain, which `SecItem` cannot
    /// reach from a Catalyst process. `result` is called before this returns,
    /// with the value when the status is `.found`.
    func readLoginKeychain(service: String, account: String, result: (MacLegacyKeyStatus, String?) -> Void)
    func writeLoginKeychain(service: String, account: String, label: String, value: String) -> Bool

    // MARK: Application

    /// "light", "dark", or nil to follow the system.
    func setAppearance(_ name: String?)
    /// Asked before the app quits; return false to keep it running.
    func setTerminationGuard(_ mayTerminate: @escaping () -> Bool)
    func terminate()
    /// Takes ⌘Q (quit) and ⌘W in a main window before the menu or the
    /// window's content sees them. `handler` answers ⌘W: true when the app
    /// closed something (or wants the key dropped), false to let it through.
    func setCloseShortcutHandler(_ handler: @escaping () -> Bool)
    /// Whether a main window has an alert sheet up.
    func isShowingSheet() -> Bool
    /// Brings the app and the given window forward.
    func activate(window uiWindow: AnyObject?)
    /// Whether any ordinary window is on screen (not a menu bar item or popover).
    func hasVisibleWindow() -> Bool
    /// An accessory app has no Dock icon or menu bar: catussh while only its menu
    /// bar items are showing.
    func setAccessory(_ accessory: Bool)

    // MARK: Windows

    /// Puts the translucent window material under a UIKit window's content.
    func installBackdrop(for uiWindow: AnyObject)

    // MARK: Dialogs

    /// A sheet on the key window. `buttons` are listed first-to-last as in
    /// NSAlert; `completion` gets the index of the one chosen, and the text
    /// field's value when `textField` (its initial value) is not nil.
    func alert(
        message: String,
        informative: String?,
        buttons: [String],
        destructiveFirstButton: Bool,
        textField: String?,
        completion: ((Int, String?) -> Void)?
    )

    /// An open panel, as a sheet on the key window. Nothing chosen is an empty array.
    func openPanel(
        message: String?,
        prompt: String?,
        directory: URL?,
        canChooseFiles: Bool,
        canChooseDirectories: Bool,
        allowsMultipleSelection: Bool,
        canCreateDirectories: Bool,
        showsHiddenFiles: Bool,
        completion: @escaping ([URL]) -> Void
    )

    // MARK: Menu bar

    /// Adds a menu bar item that plays `frames` (`CGImage`s at 2x, drawn as
    /// templates); `idleFrame` shows when the interval is zero or less. AppKit
    /// cannot read a Catalyst app's asset catalog, so the app loads them.
    func addStatusItem(_ id: String, toolTip: String, frames: [AnyObject], idleFrame: AnyObject?, onClick: @escaping () -> Void)
    func updateStatusItem(_ id: String, title: String, frameInterval: Double)
    func removeStatusItem(_ id: String)
    /// Called by "Open catussh" in a menu bar item's right-click menu.
    func setOpenAppHandler(_ handler: @escaping () -> Void)

    /// Call before asking UIKit for the scene whose window becomes a popover, so
    /// the window never shows on its own.
    func prepareForPopoverWindow()
    /// Moves a UIKit window's content into the item's popover. False until the
    /// window has its AppKit counterpart; try again on the next run loop pass.
    func attachPopover(_ id: String, window uiWindow: AnyObject, width: Double, height: Double) -> Bool
    func hasPopover(_ id: String) -> Bool
    func togglePopover(_ id: String)
    func closePopover(_ id: String)
}
