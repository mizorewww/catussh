//
//  Toolbar.swift
//  CatusshDesign
//
//  Native toolbar components for macOS and iOS.
//

import SwiftUI

public enum RXToolbar {
    public static let height: CGFloat = 32
    public static let spacing: CGFloat = 8
}

/// A choice in an `RXToolbarMenu`.
public struct RXToolbarMenuItem {
    public let title: String
    public let systemImage: String
    public let isOn: Bool
    public let action: () -> Void

    public init(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isOn = isOn
        self.action = action
    }
}

/// A symbol that opens a menu of choices in a toolbar.
public struct RXToolbarMenu: View {
    let title: String
    let systemImage: String
    let items: [RXToolbarMenuItem]

    public init(_ title: String, systemImage: String, items: [RXToolbarMenuItem]) {
        self.title = title
        self.systemImage = systemImage
        self.items = items
    }

    public var body: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(action: item.action) {
                    if item.isOn {
                        Label(item.title, systemImage: "checkmark")
                    } else {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityLabel(title)
    }
}

public extension Notification.Name {
    /// Focuses the toolbar search of the frontmost page: post it from a Find command (⌘F).
    static let rxFocusToolbarSearch = Notification.Name("RXFocusToolbarSearch")
}
