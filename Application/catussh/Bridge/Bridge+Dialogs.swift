//
//  Bridge+Dialogs.swift
//  MacBridge
//

import AppKit

extension Bridge {
    private var sheetParent: NSWindow? {
        if let key = NSApp.keyWindow, ordinaryWindows.contains(key) { return key }
        return ordinaryWindows.first { $0.isVisible }
    }

    func alert(
        message: String,
        informative: String?,
        buttons: [String],
        destructiveFirstButton: Bool,
        textField: String?,
        completion: ((Int, String?) -> Void)?
    ) {
        let alert = NSAlert()
        alert.messageText = message
        if let informative { alert.informativeText = informative }
        for (index, title) in buttons.enumerated() {
            let button = alert.addButton(withTitle: title)
            if index == 0 { button.hasDestructiveAction = destructiveFirstButton }
        }
        var field: NSTextField?
        if let textField {
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            input.stringValue = textField
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            field = input
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            completion?(index, field?.stringValue)
        }
        if let parent = sheetParent {
            alert.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            // With no window to hang a sheet on (catussh in the menu bar only),
            // the alert still must not block its caller: the quit confirmation
            // is asked from applicationShouldTerminate, which has to answer
            // before the alert does, or the terminate that follows a "Quit"
            // re-enters AppKit while it is still deciding.
            DispatchQueue.main.async {
                // An accessory app's alert would open behind the front app.
                NSApp.activate(ignoringOtherApps: true)
                finish(alert.runModal())
            }
        }
    }

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
    ) {
        let panel = NSOpenPanel()
        if let message { panel.message = message }
        if let prompt { panel.prompt = prompt }
        if let directory { panel.directoryURL = directory }
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = canCreateDirectories
        panel.showsHiddenFiles = showsHiddenFiles
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .OK ? panel.urls : [])
        }
        if let parent = sheetParent {
            panel.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
