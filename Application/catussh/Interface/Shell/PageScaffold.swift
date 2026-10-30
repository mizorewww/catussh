//
//  PageScaffold.swift
//  catussh (macOS)
//
//  The content column over the translucent window: the page title, then the page body.
//  Page controls live in the native window toolbar, which carries Liquid Glass on
//  macOS 26: navigation on the left, actions on the right with the primary one last,
//  and search as a toolbar search field.
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
        #if targetEnvironment(macCatalyst)
            .pageToolbar(primary: primary, trailingMetrics: trailingMetrics, search: search.map { ($0, searchPrompt) }) { leading } trailing: { trailing }
        #else
            .pageToolbar(primary: primary, trailingMetrics: trailingMetrics) { leading } trailing: { trailing }
            .modifier(OptionalSearch(text: search, prompt: searchPrompt))
        #endif
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
    /// Lets the toolbar float over the window material. The material itself is
    /// drawn once, behind every page, by MainView: a page that drew its own would
    /// fade with the page during a transition and flash the plain window colour.
    func pageChrome() -> some View {
        rxClearToolbar()
    }
}

/// Whether a page is the one on screen. Open session pages stay mounted so
/// switching between them is instant; the hidden ones must not add toolbar items,
/// search fields or keyboard shortcuts.
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
    /// Navigation controls at the leading edge, actions at the trailing edge, and
    /// the page's one primary action after them, apart.
    func pageToolbar<Leading: View, Trailing: View>(
        primary: ToolbarAction? = nil,
        trailingMetrics: ToolbarCapsuleMetrics = .group,
        search: (text: Binding<String>, prompt: String)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(PageToolbar(leading: leading(), trailing: trailing(), primary: primary, trailingMetrics: trailingMetrics, search: search))
    }
}

private struct PageToolbar<Leading: View, Trailing: View>: ViewModifier {
    let leading: Leading
    let trailing: Trailing
    let primary: ToolbarAction?
    let trailingMetrics: ToolbarCapsuleMetrics
    /// Search after the trailing actions; only Mac Catalyst passes it here.
    let search: (text: Binding<String>, prompt: String)?
    @Environment(\.isActivePage) private var isActive
    @Environment(\.serverToolSwitch) private var toolSwitch
    @State private var pageWidth: CGFloat = 0
    @State private var switcherWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0
    @State private var leadingWidth: CGFloat = 0

    private var hasLeading: Bool { Leading.self != EmptyView.self }
    private var hasTrailing: Bool { Trailing.self != EmptyView.self || primary != nil }

    // The condition sits inside the toolbar builder: switching the page's own
    // identity would rebuild it (and its terminal view) on every switch.
    //
    // Every control is a toolbar item of its own with the shared background
    // hidden, drawn by CatusshDesign to AppKit's measurements (see Toolbar.swift).
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
                                .toolbar {
                if isActive {
                    if hasLeading {
                        ToolbarItem(placement: .navigation) {
                            RXToolbarCapsule { leading }
                                // No wider than what the switcher and the
                                // actions leave: past that its content (a
                                // terminal's tabs) scrolls, instead of the
                                // toolbar moving items into its overflow menu.
                                .frame(maxWidth: leadingLimit)
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
                                .padding(.leading, 4)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    ToolbarSpacer(.flexible)
                    if let toolSwitch {
                        // The toolbar packs this against the trailing items, its
                        // spacers notwithstanding; the padding moves it back to the
                        // middle of the page, as AppKit's centred item sits.
                        ToolbarItem(placement: .automatic) {
                            ServerToolSwitcher(machine: toolSwitch.machine, current: toolSwitch.current)
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { switcherWidth = $0 }
                                .padding(.trailing, switcherOffset)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.flexible)
                    }
                    if hasTrailing {
                        ToolbarItem(placement: .automatic) {
                            RXToolbarActions(
                                spacing: trailingMetrics.spacing,
                                minSlot: trailingMetrics.minSlot,
                                primary: primary.map { action in
                                    RXToolbarPrimary(action.title, systemImage: action.systemImage, isEnabled: action.isEnabled, action: action.action)
                                }
                            ) { trailing }
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
                                .padding(.trailing, search == nil ? trailingMetrics.inset : 0)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    #if targetEnvironment(macCatalyst)
                        if let search {
                            ToolbarItem(placement: .automatic) {
                                RXToolbarSearchField(text: search.text, prompt: search.prompt)
                            }
                            .sharedBackgroundVisibility(.hidden)
                        }
                    #endif
                }
            }
        } else {
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
                    #if targetEnvironment(macCatalyst)
                        // Kept with the page's toolbar, which orders it last.
                        if let search {
                            ToolbarItem(placement: .automatic) {
                                TextField(search.prompt, text: search.text)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                        }
                    #endif
                }
            }
        }
    }

    /// What lies between the switcher and the trailing edge of the page: the
    /// trailing items, the gap before them and what the toolbar keeps, measured.
    private var trailingEnd: CGFloat {
        (hasTrailing ? trailingWidth + trailingMetrics.inset + 7 : 0) + 0.75
    }

    /// Centred in the page as far as the leading items allow; never so far
    /// that the row is wider than the window.
    private var switcherOffset: CGFloat {
        let centred = (pageWidth - switcherWidth) / 2 - trailingEnd
        let room = pageWidth - leadingWidth - switcherWidth - trailingEnd - 32
        return max(0, min(centred, room))
    }

    /// What the leading items may take: the page less the switcher, the
    /// trailing actions and the gaps between them.
    private var leadingLimit: CGFloat? {
        guard pageWidth > 0 else { return nil }
        let switcher = toolSwitch == nil ? 0 : switcherWidth + 24
        return max(120, pageWidth - switcher - trailingEnd - 40)
    }
}

/// How AppKit spaces the symbols of a toolbar group.
struct ToolbarCapsuleMetrics {
    var spacing: CGFloat = 0
    var minSlot: CGFloat = 35
    /// From the trailing edge of the window, past the toolbar's own margin.
    var inset: CGFloat = 4

    /// Buttons in a `ToolbarItemGroup`.
    static let group = ToolbarCapsuleMetrics()
    /// A lone button: no minimum width.
    static let single = ToolbarCapsuleMetrics(minSlot: 0)
    /// A `ControlGroup`.
    static let controlGroup = ToolbarCapsuleMetrics(spacing: 9, minSlot: 34.5, inset: 0)
}

/// Toolbar search for pages that are never kept hidden (session pages search
/// inside the page instead: a hidden page's search field would stay in the toolbar).
private struct OptionalSearch: ViewModifier {
    let text: Binding<String>?
    let prompt: String

    func body(content: Content) -> some View {
        if let text {
            content.searchable(text: text, placement: .toolbar, prompt: prompt)
        } else {
            content
        }
    }
}

/// A toolbar action: a symbol, with its title as the tooltip and accessibility
/// label (HIG: prefer simple, recognizable symbols in toolbars). A page passes
/// its primary action to the scaffold, which draws it tinted and apart.
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
