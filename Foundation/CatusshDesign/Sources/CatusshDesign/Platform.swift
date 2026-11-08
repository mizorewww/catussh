//
//  Platform.swift
//  CatusshDesign
//
//  Control styles that exist on one platform only, expressed once so views can
//  stay shared between macOS and iOS.
//

import SwiftUI

public extension View {
    /// A checkbox on the Mac; iOS has no checkbox, so a switch there.
    func rxCheckboxToggle() -> some View {
        #if os(macOS)
            toggleStyle(.checkbox)
        #else
            toggleStyle(.switch)
        #endif
    }

    /// A switch.
    func rxSwitchToggle() -> some View {
        toggleStyle(.switch)
    }

    /// An indeterminate spinner at AppKit's regular size.
    func rxSpinner() -> some View {
        controlSize(.regular)
    }

    /// A menu drawn as a button.
    func rxButtonMenu(indicator: Bool = true) -> some View {
        #if os(macOS)
            menuStyle(.button).menuIndicator(indicator ? .automatic : .hidden)
        #else
            menuIndicator(indicator ? .automatic : .hidden)
        #endif
    }

    /// An inline text link.
    func rxLinkButton() -> some View {
        #if os(macOS)
            buttonStyle(.link)
        #else
            buttonStyle(.borderless)
        #endif
    }

    /// Lets the window toolbar float over the page instead of drawing its own background.
    func rxClearToolbar() -> some View {
        #if os(macOS)
            toolbarBackground(.hidden, for: .windowToolbar)
        #else
            toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }
}

private struct RXControlsAtRestKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var rxControlsAtRest: Bool {
        get { self[RXControlsAtRestKey.self] }
        set { self[RXControlsAtRestKey.self] = newValue }
    }
}
