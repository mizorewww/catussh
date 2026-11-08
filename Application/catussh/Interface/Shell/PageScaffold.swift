//
//  PageScaffold.swift
//  catussh (macOS)
//

import CatusshDesign
import CatusshModule
import SwiftUI

struct PageScaffold<Leading: View, Trailing: View, Header: View, Content: View>: View {
    let scrolls: Bool
    let search: Binding<String>?
    let searchPrompt: String
    let primary: ToolbarAction?
    let trailingMetrics: ToolbarCapsuleMetrics
    let leading: Leading
    let trailing: Trailing
    let header: Header
    let content: Content

    init(
        scrolls: Bool = true,
        search: Binding<String>? = nil,
        searchPrompt: String = "Search",
        primary: ToolbarAction? = nil,
        trailingMetrics: ToolbarCapsuleMetrics = .group,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.scrolls = scrolls
        self.search = search
        self.searchPrompt = searchPrompt
        self.primary = primary
        self.trailingMetrics = trailingMetrics
        self.leading = leading()
        self.trailing = trailing()
        self.header = header()
        self.content = content()
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        content
                            .padding(.top, RX.Space.s6)
                    }
                    .padding(.horizontal, RX.Space.s6)
                    .padding(.top, RX.Space.s3)
                    .padding(.bottom, RX.Space.s6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    content
                        .padding(.top, RX.Space.s6)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, RX.Space.s6)
                .padding(.top, RX.Space.s3)
                .padding(.bottom, RX.Space.s6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .pageChrome()
        .pageToolbar(primary: primary, trailingMetrics: trailingMetrics) { leading } trailing: { trailing }
        .modifier(OptionalSearch(text: search, prompt: searchPrompt))
    }
}

extension PageScaffold where Header == EmptyView {
    init(
        scrolls: Bool = true,
        search: Binding<String>? = nil,
        searchPrompt: String = "Search",
        primary: ToolbarAction? = nil,
        trailingMetrics: ToolbarCapsuleMetrics = .group,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.init(scrolls: scrolls, search: search, searchPrompt: searchPrompt, primary: primary, trailingMetrics: trailingMetrics, leading: leading, trailing: trailing, header: { EmptyView() }, content: content)
    }
}

extension View {
    func pageChrome() -> some View {
        rxClearToolbar()
    }
}

private struct ActivePageKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isActivePage: Bool {
        get { self[ActivePageKey.self] }
        set { self[ActivePageKey.self] = newValue }
    }
}

extension View {
    func pageToolbar<Leading: View, Trailing: View>(
        primary: ToolbarAction? = nil,
        trailingMetrics: ToolbarCapsuleMetrics = .group,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(PageToolbar(leading: leading(), trailing: trailing(), primary: primary, trailingMetrics: trailingMetrics))
    }
}

private struct PageToolbar<Leading: View, Trailing: View>: ViewModifier {
    let leading: Leading
    let trailing: Trailing
    let primary: ToolbarAction?
    let trailingMetrics: ToolbarCapsuleMetrics
    @Environment(\.isActivePage) private var isActive
    @Environment(\.serverToolSwitch) private var toolSwitch

    func body(content: Content) -> some View {
        content.toolbar {
            if isActive {
                ToolbarItemGroup(placement: .navigation) { leading }
                if let toolSwitch {
                    ToolbarItem(placement: .principal) {
                        ServerToolSwitcher(machine: toolSwitch.machine, current: toolSwitch.current)
                    }
                }
                ToolbarItemGroup(placement: .automatic) {
                    trailing
                    if let primary { primary }
                }
            }
        }
    }
}

struct ToolbarCapsuleMetrics {
    var spacing: CGFloat = 0
    var minSlot: CGFloat = 35
    var inset: CGFloat = 4

    static let group = ToolbarCapsuleMetrics()
    static let single = ToolbarCapsuleMetrics(minSlot: 0)
    static let controlGroup = ToolbarCapsuleMetrics(spacing: 9, minSlot: 34.5, inset: 0)
}

private struct OptionalSearch: ViewModifier {
    let text: Binding<String>?
    let prompt: String
    @Environment(\.isActivePage) private var isActive

    func body(content: Content) -> some View {
        if let text, isActive {
            content.searchable(text: text, placement: .toolbar, prompt: prompt)
        } else {
            content
        }
    }
}

struct ToolbarAction: View {
    let title: String
    let systemImage: String
    var primary = false
    var isEnabled = true
    let action: () -> Void

    init(_ title: String, systemImage: String, primary: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.primary = primary
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        if primary {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .rxPrimaryAction()
            .disabled(!isEnabled)
            .help(title)
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
            }
            .disabled(!isEnabled)
            .help(title)
        }
    }
}
