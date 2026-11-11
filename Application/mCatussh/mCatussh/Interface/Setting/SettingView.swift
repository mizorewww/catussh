//
//  SettingView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/2.
//
//  Settings is the shared CatusshTerminal layout (the same categories and order as
//  on macOS: General, Connection, then the terminal, then About); this file
//  supplies the rows for catussh's own preferences on iOS.
//

import CatusshModule
import CatusshTerminal
import SwiftUI

struct SettingView: View {
    @ObservedObject var store = CatusshStore.shared

    var body: some View {
        GhosttyConfigurationView(
            hostSections: [
                ConfigHostSettingsSection(id: "general.appearance", keywords: "appearance dark light mode theme system") {
                    AppearanceSettings()
                },
                ConfigHostSettingsSection(id: "general.sessions", keywords: "open sessions automatically ask before closing confirmation") {
                    SessionSettings()
                },
                ConfigHostSettingsSection(id: "general.recent", keywords: "recent servers history quick connect commands record remember") {
                    RecentSettings()
                },
                ConfigHostSettingsSection(id: "general.sync", keywords: "icloud sync cloud encrypted passphrase servers identities credentials devices") {
                    CloudSyncSettings()
                },
                ConfigHostSettingsSection(id: "general.data", keywords: "data container files log diagnostics") {
                    DataSettings()
                },
                ConfigHostSettingsSection(id: "connection.ssh", keywords: "ssh timeout connect wait host key known hosts fingerprint") {
                    SSHSettings()
                },
                ConfigHostSettingsSection(id: "connection.monitor", keywords: "monitor refresh interval status") {
                    MonitorSettings()
                },
                ConfigHostSettingsSection(id: "terminal.copyOnSelect", keywords: "copy on select selection clipboard pasteboard automatically") {
                    CopyOnSelectSettings()
                },
                ConfigHostSettingsSection(id: "about.catussh", keywords: "version build license source github issues") {
                    AboutSettings()
                },
                ConfigHostSettingsSection(id: "about.acknowledgements", keywords: "acknowledgements credits libraries ghostty") {
                    AcknowledgementSettings()
                },
            ],
            onApplied: { size in
                // One font size: the terminal's Size setting also sets the size
                // new sessions start from.
                if let size { store.terminalFontSize = Int(size.rounded()) }
            }
        )
    }
}

/// Light or dark, applied to every window of the app.
enum AppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    static let key = "me.mizorewww.rayon.appearance"

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            for window in (scene as? UIWindowScene)?.windows ?? [] {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    @MainActor
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: key) ?? AppearancePreference.system.rawValue
        (AppearancePreference(rawValue: raw) ?? .system).apply()
    }
}

private struct AppearanceSettings: View {
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system.rawValue

    var body: some View {
        RXFormRow("Light or dark", description: "Terminal colors are set under Colors.") {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag(AppearancePreference.system.rawValue)
                Text("Light").tag(AppearancePreference.light.rawValue)
                Text("Dark").tag(AppearancePreference.dark.rawValue)
            }
            .labelsHidden()
            .fixedSize()
        }
        .onChange(of: appearance) { raw in
            (AppearancePreference(rawValue: raw) ?? .system).apply()
        }
    }
}

private struct SessionSettings: View {
    @ObservedObject var store = CatusshStore.shared

    var body: some View {
        RXDividedStack {
            SwitchRow(
                "Show a session when it connects",
                description: "Open the terminal as soon as it connects.",
                isOn: $store.openInterfaceAutomatically
            )
            SwitchRow(
                "Ask before closing a session",
                description: "Confirm before closing a connected terminal.",
                isOn: Binding(get: { !store.disableConformation }, set: { store.disableConformation = !$0 })
            )
        }
    }
}

private struct RecentSettings: View {
    @ObservedObject var store = CatusshStore.shared
    @AppStorage("me.mizorewww.rayon.maxRecentRecordCount") private var recentLimit = 8

    var body: some View {
        RXDividedStack {
            SwitchRow("Remember recent servers", description: "Listed under Quick Connect on Home.", isOn: $store.storeRecent)
            NumberFieldRow("Number to keep", value: $recentLimit, in: 1 ... 50)
                .disabled(!store.storeRecent)
            SwitchRow(
                "Include Quick Connect commands",
                description: "Also remember user@host commands typed on Home.",
                isOn: $store.saveTemporarySession
            )
            .disabled(!store.storeRecent)
        }
        .onChange(of: recentLimit) { limit in
            store.maxRecentRecordCount = limit
            if store.recentRecord.count > limit {
                store.recentRecord = Array(store.recentRecord.prefix(limit))
            }
        }
    }
}

private struct DataSettings: View {
    #if DEBUG
        @State private var redirectLog = UserDefaults.standard.value(forKey: "me.mizorewww.redirect.diag") as? Bool ?? false
    #endif

    var body: some View {
        RXDividedStack {
            RXFormRow("App container", description: "Files the app keeps, in the Files app.") {
                Button("Show") { UIBridge.openFileContainer() }
                    .buttonStyle(.rx(size: .small))
            }
            NavigationLink {
                LogView()
            } label: {
                RXFormRow("App log", description: "Diagnostics for reporting a problem.") {
                    Image(systemName: "chevron.right").foregroundStyle(.rxInkTertiary)
                }
            }
            .buttonStyle(.plain)
            #if DEBUG
                SwitchRow(
                    "Redirect log",
                    description: "Takes effect after restarting the app.",
                    isOn: $redirectLog
                )
                .onChange(of: redirectLog) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "me.mizorewww.redirect.diag")
                }
            #endif
        }
    }
}

private struct SSHSettings: View {
    @ObservedObject var store = CatusshStore.shared

    var body: some View {
        RXDividedStack {
            NumberFieldRow(
                "Connection timeout",
                description: "How long to wait for a server before giving up.",
                value: $store.timeout,
                in: 2 ... 30,
                unit: "s"
            )
            HostKeysRow()
        }
    }
}

/// How many host keys are saved, and a way to start over.
private struct HostKeysRow: View {
    @State private var count = KnownHosts.shared.count

    var body: some View {
        RXFormRow(
            "Saved host keys",
            description: "A server's key is saved the first time you connect; a server that later presents another key is refused. \(count) saved."
        ) {
            Button("Forget All…") {
                UIBridge.requiresConfirmation(message: "Forget all saved host keys?") { confirmed in
                    guard confirmed else { return }
                    KnownHosts.shared.forgetAll()
                    count = KnownHosts.shared.count
                }
            }
            .buttonStyle(.rx(size: .small))
            .disabled(count == 0)
        }
        .onAppear { count = KnownHosts.shared.count }
    }
}

private struct MonitorSettings: View {
    @ObservedObject var store = CatusshStore.shared
    private let intervals = [5, 10, 15, 30, 60]

    var body: some View {
        RXFormRow("Refresh", description: "How often an open monitor reads the server.") {
            Picker("Refresh", selection: Binding(get: { max(5, store.monitorInterval) }, set: { store.monitorInterval = $0 })) {
                ForEach(intervals, id: \.self) { Text("Every \($0) s").tag($0) }
                if !intervals.contains(max(5, store.monitorInterval)) {
                    Text("Every \(store.monitorInterval) s").tag(store.monitorInterval)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// Terminal, Mouse & Clipboard: the row above Ghostty's copy settings.
private struct CopyOnSelectSettings: View {
    @ObservedObject var store = CatusshStore.shared

    var body: some View {
        SwitchRow(
            "Copy on select",
            description: "Copy text to the clipboard as soon as you finish selecting it.",
            isOn: $store.terminalCopyOnSelect
        )
        .onChange(of: store.terminalCopyOnSelect) { enabled in
            CatusshTerminalView.setCopyOnSelect(enabled)
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        RXDividedStack {
            RXFormRow("Version") {
                Text(appVersion)
                    .font(.rxBody.monospacedDigit())
                    .foregroundStyle(.rxInkSecondary)
            }
            RXFormRow("Source code", description: "mizorewww/catussh on GitHub") {
                Link("GitHub", destination: URL(string: "https://github.com/mizorewww/catussh")!)
            }
            RXFormRow("Report a problem") {
                Link("Issues", destination: URL(string: "https://github.com/mizorewww/catussh/issues")!)
            }
            NavigationLink {
                LicenseView()
            } label: {
                RXFormRow("License") {
                    Image(systemName: "chevron.right").foregroundStyle(.rxInkTertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct AcknowledgementSettings: View {
    var body: some View {
        RXDividedStack {
            RXFormRow("Maintained by", description: "mizorewww") {
                EmptyView()
            }
            RXFormRow("Originally created by", description: "Lakr Aream (@Lakr233) with @__oquery, @zlind0, @unixzii, @82flex and @xnth97. This version is not affiliated with or endorsed by them.") {
                EmptyView()
            }
            RXFormRow("Terminal", description: "Ghostty and its configuration catalog (MIT, Ghostty contributors).") {
                EmptyView()
            }
        }
    }
}
