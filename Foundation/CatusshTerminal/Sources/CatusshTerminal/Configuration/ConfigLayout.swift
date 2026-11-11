import Foundation

/// How Settings is organised. catussh's own preferences and the Ghostty settings
/// catussh applies share one list of categories, ordered from what people change
/// most (General, the terminal's text and colours) to what they rarely touch
/// (Advanced, About). Each category holds titled groups; a group lists catalog
/// keys or a block of rows supplied by the app (`ConfigHostSettingsSection`).
struct ConfigLayout {
    enum Item: Hashable {
        /// A Ghostty setting, by catalog key.
        case setting(String)
        /// Rows supplied by the app, by `ConfigHostSettingsSection.id`.
        case host(String)
    }

    struct Group: Identifiable {
        let id: String
        let title: String
        let items: [Item]

        init(_ id: String, _ title: String, _ items: [Item]) {
            self.id = id
            self.title = title
            self.items = items
        }

        init(_ id: String, _ title: String, keys: [String]) {
            self.init(id, title, keys.map(Item.setting))
        }
    }

    struct Category: Identifiable {
        enum Section: String { case app = "catussh", terminal = "Terminal", info = "" }

        let id: String
        let title: String
        let icon: String
        let section: Section
        let groups: [Group]

        /// Ghostty keys in this category.
        var keys: [String] {
            groups.flatMap(\.items).compactMap { item in
                if case let .setting(key) = item { return key }
                return nil
            }
        }

        /// Shows the live terminal preview beside it.
        var previews: Bool { section == .terminal && id != "keyboard" }
    }

    static let categories: [Category] = [
        Category(id: "general", title: "General", icon: "gearshape", section: .app, groups: [
            Group("appearance", "Appearance", [.host("general.appearance")]),
            Group("sessions", "Sessions", [.host("general.sessions")]),
            Group("recent", "Recent", [.host("general.recent")]),
            Group("sync", "iCloud Sync", [.host("general.sync")]),
            // App-specific: the iOS app's container and log. A group shows only
            // when the app supplies its rows.
            Group("data", "Data", [.host("general.data")]),
        ]),
        Category(id: "connection", title: "Connection", icon: "network", section: .app, groups: [
            Group("ssh", "SSH", [.host("connection.ssh")]),
            Group("uuremote", "NetEase UU Remote", [.host("connection.uuremote")]),
            Group("monitor", "Monitor", [.host("connection.monitor")]),
        ]),
        Category(id: "text", title: "Text", icon: "textformat", section: .terminal, groups: [
            Group("font", "Font", keys: ["font-family", "font-style", "font-size", "font-thicken", "font-thicken-strength"]),
            Group("styles", "Bold and Italic", keys: [
                "font-family-bold", "font-style-bold", "font-family-italic", "font-style-italic",
                "font-family-bold-italic", "font-style-bold-italic", "font-synthetic-style",
            ]),
            Group("features", "Features and Variations", keys: [
                "font-feature", "font-variation", "font-variation-bold", "font-variation-italic", "font-variation-bold-italic",
            ]),
            Group("glyphs", "Glyphs", keys: ["font-codepoint-map", "grapheme-width-method"]),
            Group("metrics", "Cell Metrics", keys: [
                "adjust-cell-width", "adjust-cell-height", "adjust-font-baseline",
                "adjust-underline-position", "adjust-underline-thickness",
                "adjust-strikethrough-position", "adjust-strikethrough-thickness",
                "adjust-overline-position", "adjust-overline-thickness", "adjust-box-thickness",
            ]),
        ]),
        Category(id: "colors", title: "Colors", icon: "paintpalette", section: .terminal, groups: [
            Group("theme", "Theme", keys: ["theme"]),
            Group("base", "Text and Background", keys: ["foreground", "background", "bold-color", "minimum-contrast"]),
            Group("selection", "Selection", keys: ["selection-foreground", "selection-background"]),
            Group("palette", "Palette", keys: ["palette"]),
        ]),
        Category(id: "cursor", title: "Cursor", icon: "character.cursor.ibeam", section: .terminal, groups: [
            Group("shape", "Shape", keys: ["cursor-style", "cursor-style-blink", "adjust-cursor-thickness", "adjust-cursor-height"]),
            Group("color", "Color", keys: ["cursor-color", "cursor-text", "cursor-opacity"]),
        ]),
        Category(id: "window", title: "Window", icon: "macwindow", section: .terminal, groups: [
            Group("transparency", "Transparency", keys: ["background-opacity", "background-opacity-cells"]),
            Group("padding", "Padding", keys: ["window-padding-x", "window-padding-y", "window-padding-balance", "window-padding-color"]),
        ]),
        Category(id: "input", title: "Mouse & Clipboard", icon: "cursorarrow.click", section: .terminal, groups: [
            // Copy on Select is the app's own row (`terminal.copyOnSelect`): a
            // touch selection never passes through Ghostty's `copy-on-select`.
            Group("copy", "Copy and Paste", [.host("terminal.copyOnSelect")] + [
                "clipboard-trim-trailing-spaces", "selection-clear-on-copy",
                "selection-clear-on-typing", "clipboard-paste-protection", "clipboard-paste-bracketed-safe",
            ].map(Item.setting)),
            Group("mouse", "Mouse", keys: ["mouse-scroll-multiplier", "mouse-hide-while-typing", "mouse-shift-capture", "cursor-click-to-move", "link-url"]),
        ]),
        Category(id: "keyboard", title: "Keyboard", icon: "keyboard", section: .terminal, groups: [
            Group("keybinds", "Shortcuts", keys: ["keybind"]),
        ]),
        Category(id: "advanced", title: "Advanced", icon: "slider.horizontal.3", section: .terminal, groups: [
            Group("memory", "Memory", keys: ["scrollback-limit", "image-storage-limit"]),
            Group("compatibility", "Compatibility", keys: ["title", "enquiry-response", "vt-kam-allowed"]),
        ]),
        Category(id: "about", title: "About", icon: "info.circle", section: .info, groups: [
            Group("catussh", "catussh", [.host("about.catussh")]),
            Group("acknowledgements", "Acknowledgements", [.host("about.acknowledgements")]),
        ]),
    ]

    /// Supported keys Settings deliberately leaves out: `background-blur` blurs a
    /// standalone Ghostty window and has no effect inside catussh, whose window
    /// material already blurs; `freetype-load-flags` is Linux-only.
    static let hiddenKeys: Set<String> = ["background-blur", "freetype-load-flags"]

    static let categoryOfKey: [String: Category] = {
        var result: [String: Category] = [:]
        for category in categories {
            for key in category.keys where result[key] == nil { result[key] = category }
        }
        return result
    }()

    static let groupOfKey: [String: Group] = {
        var result: [String: Group] = [:]
        for category in categories {
            for group in category.groups {
                for case let .setting(key) in group.items where result[key] == nil { result[key] = group }
            }
        }
        return result
    }()

    static func category(_ id: String) -> Category? { categories.first { $0.id == id } }

    // MARK: Wording

    /// catussh's wording where the catalog's is written for standalone Ghostty, or
    /// no longer matches the control (sizes edited in MB, fonts picked from a list).
    static let wording: [String: (title: String, summary: String?)] = [
        "font-family": ("Font", "The typeface for terminal text, then fallbacks for characters it lacks."),
        "font-style": ("Style", "Which of the font's styles regular text uses."),
        "font-size": ("Size", "Text size in points. ⌘+ and ⌘− change it for one session."),
        "font-thicken": ("Thicken strokes", "Draw text with a heavier stroke, like Terminal on macOS."),
        "font-thicken-strength": ("Thickening amount", "How much heavier strokes are drawn while thickening is on."),
        "font-family-bold": ("Bold font", nil),
        "font-style-bold": ("Bold style", nil),
        "font-family-italic": ("Italic font", nil),
        "font-style-italic": ("Italic style", nil),
        "font-family-bold-italic": ("Bold italic font", nil),
        "font-style-bold-italic": ("Bold italic style", nil),
        "font-feature": ("OpenType features", "Turn ligatures and stylistic alternates on or off."),
        "font-variation": ("Variation axes", "Weight, width or slant of a variable font."),
        "font-variation-bold": ("Bold variation axes", nil),
        "font-variation-italic": ("Italic variation axes", nil),
        "font-variation-bold-italic": ("Bold italic variation axes", nil),
        "font-codepoint-map": ("Font for character ranges", "Draw specific Unicode ranges, such as icons, with another font."),
        "background-opacity": ("Background opacity", "Below 1, the window behind shows through the terminal background."),
        "background-opacity-cells": ("Apply opacity to colored cells", "Also make cells with their own background color translucent."),
        "window-padding-x": ("Horizontal padding", "Space between the text and the left and right edges, in points."),
        "window-padding-y": ("Vertical padding", "Space between the text and the top and bottom edges, in points."),
        "window-padding-balance": ("Balance padding", "Spread leftover space evenly around the text."),
        "scrollback-limit": ("Scrollback", "Memory kept for lines that have scrolled off screen."),
        "image-storage-limit": ("Images", "Memory kept for images shown in the terminal."),
        "title": ("Fixed session title", "Use this instead of the title the remote shell sets."),
        "mouse-scroll-multiplier": ("Scroll speed", "Multiplies trackpad (precise) and mouse wheel (line) scrolling."),
        "cursor-click-to-move": ("Option-click moves the cursor", "Option-click at a prompt to move the cursor there."),
        "link-url": ("Detect links", "⌘-click URLs in terminal output to open them."),
        "cursor-style": ("Style", nil),
        "cursor-style-blink": ("Blinking", "Whether the cursor blinks; programs can still ask for either."),
        "adjust-cursor-thickness": ("Bar thickness", "Width of the bar and hollow-block cursor, in points or percent."),
        "adjust-cursor-height": ("Height", "Height of the cursor, in points or percent."),
        "cursor-color": ("Fill", "Color of the cursor itself."),
        "cursor-text": ("Text under the cursor", nil),
        "cursor-opacity": ("Opacity", nil),
    ]

    static func title(_ setting: ConfigSetting) -> String {
        wording[setting.key]?.title ?? setting.name
    }

    /// Human names for option values the catalog leaves raw.
    static let optionNames: [String: [String: String]] = [
        "cursor-style": ["block": "Block", "bar": "Bar", "underline": "Underline", "block_hollow": "Hollow"],
        "cursor-style-blink": ["true": "Blink", "false": "Steady", "": "Auto"],
        "mouse-shift-capture": ["false": "Off (programs can opt in)", "true": "On (programs can opt out)", "always": "Always", "never": "Never"],
        "window-padding-color": ["background": "Background color", "extend": "Extend edge cells", "extend-always": "Always extend edge cells"],
    ]

    static func optionName(_ key: String, value: String, fallback: String) -> String {
        optionNames[key]?[value] ?? fallback
    }
}
