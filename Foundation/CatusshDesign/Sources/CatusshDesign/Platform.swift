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
            toggleStyle(.checkbox).tint(.rxAccent)
        #else
            toggleStyle(.switch).tint(.rxAccent)
        #endif
    }

    /// A switch.
    func rxSwitchToggle() -> some View {
        toggleStyle(.switch).tint(.rxAccent)
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
        buttonStyle(.plain).foregroundStyle(Color.rxAccent)
    }

    /// Lets the window toolbar float over the page instead of drawing its own
    /// background. Mac only: on iOS a bar without a background is Liquid
    /// Glass over the page, which loses its text in Light mode.
    @ViewBuilder
    func rxClearToolbar() -> some View {
        #if os(macOS)
            toolbarBackground(.hidden, for: .windowToolbar)
        #else
            self
        #endif
    }
}

public extension View {
    /// Bars that keep their text readable. Since iOS 26 the navigation bar,
    /// toolbar and tab bar are Liquid Glass with the page scrolling on under
    /// them, and the glass takes its tint from whatever passes behind: in
    /// Light mode rows show through the tab bar and bar titles and labels
    /// sink into them. A hard scroll edge gives every bar an opaque backing
    /// of the page's own color, so nothing shows through and the glass has
    /// nothing to follow. Set once at the root; scroll views inherit it.
    @ViewBuilder
    func rxSolidBars() -> some View {
        #if os(iOS)
            if #available(iOS 26.0, *) {
                scrollEdgeEffectStyle(.hard, for: .all)
            } else {
                self
            }
        #else
            self
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
