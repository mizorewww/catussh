//
//  Generic.swift
//  catussh (macOS)
//
//  Native AppKit sheet presentation and picker panels.
//

import AppKit
import CatusshModule
import SwiftUI

enum CatusshUtil {
    @MainActor static var isShowingSheetOrModal: Bool {
        if NSApp.modalWindow != nil { return true }
        return MainWindow.ordinaryWindows.contains { $0.attachedSheet != nil }
    }
}

/// Presents SwiftUI content as a native AppKit sheet on the frontmost window.
enum SheetPresenter {
    @MainActor
    static func present<Content: View>(
        size: CGSize? = nil,
        @ViewBuilder content: @escaping (_ dismiss: @escaping () -> Void) -> Content
    ) {
        guard let parentWindow = UIBridge.sheetParentWindow else { return }
        weak var sheetWindowRef: NSWindow?
        let dismiss = {
            if let sheetWindow = sheetWindowRef {
                sheetWindow.sheetParent?.endSheet(sheetWindow)
            }
        }
        let root = content(dismiss)
            .environmentObject(CatusshStore.shared)
            .frame(width: size?.width, height: size?.height)
        let controller = NSHostingController(rootView: root)
        if #available(macOS 13.0, *) {
            controller.sizingOptions = .preferredContentSize
        }
        let sheetWindow = NSWindow(contentViewController: controller)
        sheetWindow.styleMask = [.titled, .fullSizeContentView]
        sheetWindow.titleVisibility = .hidden
        sheetWindow.titlebarAppearsTransparent = true
        sheetWindowRef = sheetWindow
        parentWindow.beginSheet(sheetWindow)
    }
}

enum ServerPickerPanel {
    @MainActor
    static func present(
        title: String,
        lead: String? = nil,
        confirmTitle: String,
        allowsMany: Bool,
        preselected: Set<RDMachine.ID> = [],
        onComplete: @escaping ([RDMachine.ID]) -> Void
    ) {
        SheetPresenter.present { dismiss in
            ServerPickerSheet(
                title: title,
                lead: lead,
                confirmTitle: confirmTitle,
                allowsMany: allowsMany,
                initialSelection: preselected
            ) { selection in
                dismiss()
                guard let selection, !selection.isEmpty else { return }
                onComplete(selection)
            }
        }
    }
}

enum IdentityPickerPanel {
    @MainActor
    static func present(onComplete: @escaping (RDIdentity.ID?) -> Void) {
        SheetPresenter.present { dismiss in
            IdentityPickerSheet { selection in
                dismiss()
                onComplete(selection)
            }
        }
    }
}
