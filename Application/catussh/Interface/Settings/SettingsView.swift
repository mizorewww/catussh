//
//  SettingsView.swift
//  catussh (macOS)
//
//  Settings is a sidebar destination. Its categories and their order come from
//  CatusshTerminal's ConfigLayout; this file supplies the rows for catussh's own
//  preferences (General, Connection, About).
//

import AppKit
import CatusshModule
import CatusshTerminal
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: CatusshStore
    @ObservedObject var router = AppRouter.shared
    /// False while Settings is kept out of sight.
    var active = true

    var body: some View {
        GhosttyConfigurationView(
            embedded: true,
            // Each category's page is hosted on its own, so the rows carry the
            // store with them.
            hostSections: [
                ConfigHostSettingsSection(id: "general.appearance", keywords: "appearance dark light mode theme system") {
                    AppearanceSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "general.sessions", keywords: "open sessions automatically ask before closing confirmation quit") {
                    SessionSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "general.recent", keywords: "recent servers history quick connect commands record remember") {
                    RecentSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "general.sync", keywords: "icloud sync cloud encrypted passphrase servers identities credentials devices") {
                    CloudSyncSettings()
                },
                ConfigHostSettingsSection(id: "general.data", keywords: "backup export import restore ssh config openssh archive") {
                    DataBackupSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "connection.ssh", keywords: "ssh timeout connect wait host key known hosts fingerprint") {
                    SSHSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "connection.uuremote", keywords: "uu remote netease remote desktop device account qr login") {
                    UURemoteSettings()
                },
                ConfigHostSettingsSection(id: "connection.monitor", keywords: "monitor refresh interval status") {
                    MonitorSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "terminal.copyOnSelect", keywords: "copy on select selection clipboard pasteboard automatically") {
                    CopyOnSelectSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "about.catussh", keywords: "version build license source github agreement") {
                    AboutSettings().environmentObject(store)
                },
                ConfigHostSettingsSection(id: "about.acknowledgements", keywords: "acknowledgements credits libraries ghostty") {
                    AcknowledgementSettings().environmentObject(store)
                },
            ],
            navigation: router.settingsNavigation,
            active: active,
            onApplied: { size in
                // One font size: the terminal's Font Size setting also sets the
                // size ⌘+ and ⌘− start from.
                if let size { store.terminalFontSize = Int(size.rounded()) }
            }
        )
    }
}

/// Appearance follows the system unless the user picks Light or Dark.
enum AppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    static let key = "me.mizorewww.rayon.appearance"

    @MainActor
    func apply() {
        switch self {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
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
            RXSegmented(selection: $appearance, options: [
                .init(AppearancePreference.system.rawValue, "System"),
                .init(AppearancePreference.light.rawValue, "Light"),
                .init(AppearancePreference.dark.rawValue, "Dark"),
            ], caps: false)
        }
        .onChange(of: appearance) { raw in
            (AppearancePreference(rawValue: raw) ?? .system).apply()
        }
    }
}

private struct SessionSettings: View {
    @EnvironmentObject var store: CatusshStore

    var body: some View {
        RXDividedStack {
            SwitchRow(
                "Show a session when it connects",
                description: "Switch to a terminal as soon as it opens.",
                isOn: $store.openInterfaceAutomatically
            )
            SwitchRow(
                "Ask before closing a session",
                description: "Confirm before closing a connected terminal or quitting.",
                isOn: Binding(get: { !store.disableConformation }, set: { store.disableConformation = !$0 })
            )
        }
    }
}

private struct RecentSettings: View {
    @EnvironmentObject var store: CatusshStore
    @AppStorage("me.mizorewww.rayon.maxRecentRecordCount") private var recentLimit = 8

    var body: some View {
        RXDividedStack {
            SwitchRow(
                "Remember recent servers",
                description: "Listed under Quick Connect on Home.",
                isOn: $store.storeRecent
            )
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

private struct SSHSettings: View {
    @EnvironmentObject var store: CatusshStore
    @State private var installsTerminfo = GhosttyTerminfo.installsAutomatically

    var body: some View {
        RXDividedStack {
            NumberFieldRow(
                "Connection timeout",
                description: "How long to wait for a server before giving up.",
                value: $store.timeout,
                in: 2 ... 30,
                unit: "s"
            )
            SwitchRow(
                "Install Ghostty's terminfo",
                description: "catussh's terminal is Ghostty. On a server that lacks its terminfo, catussh adds it to ~/.terminfo once, so programs there use every feature; nothing else on the server changes. When off, or where it cannot be added, sessions run as xterm-256color.",
                isOn: Binding(
                    get: { installsTerminfo },
                    set: { installsTerminfo = $0; GhosttyTerminfo.installsAutomatically = $0 }
                )
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
                UIBridge.requiresConfirmation(
                    message: "Forget all saved host keys?",
                    informative: "The key each server presents on its next connection is saved as its key.",
                    confirmTitle: "Forget All"
                ) { confirmed in
                    guard confirmed else { return }
                    KnownHosts.shared.forgetAll()
                    count = KnownHosts.shared.count
                }
            }
            .buttonStyle(.rx)
            .disabled(count == 0)
        }
        .onAppear { count = KnownHosts.shared.count }
    }
}

/// Terminal, Mouse & Clipboard: the row above Ghostty's copy settings.
private struct CopyOnSelectSettings: View {
    @EnvironmentObject var store: CatusshStore

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

private struct MonitorSettings: View {
    @EnvironmentObject var store: CatusshStore
    private let intervals = [5, 10, 15, 30, 60]

    var body: some View {
        RXFormRow("Refresh", description: "How often an open monitor reads the server.") {
            Picker("Refresh", selection: Binding(get: { max(5, store.monitorInterval) }, set: { store.monitorInterval = $0 })) {
                ForEach(intervals, id: \.self) { seconds in
                    Text("Every \(seconds) s").tag(seconds)
                }
                if !intervals.contains(max(5, store.monitorInterval)) {
                    Text("Every \(store.monitorInterval) s").tag(store.monitorInterval)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// The NetEase UU Remote account behind the remote desktop feature.
private struct UURemoteSettings: View {
    @ObservedObject private var account = UURemoteAccountStore.shared

    var body: some View {
        RXDividedStack {
            RXFormRow(
                "Account",
                description: "Signs the built-in UU Remote client in with QR code, SMS or an imported token."
            ) {
                HStack(spacing: RX.Space.s3) {
                    if account.isLoggedIn {
                        Label(account.nickname.isEmpty ? "Signed in" : account.nickname,
                              systemImage: "person.crop.circle")
                            .lineLimit(1)
                        Button("Manage…") { openAccountSheet() }
                            .buttonStyle(.rx)
                        Button("Sign Out") { account.logout() }
                            .buttonStyle(.rx)
                    } else {
                        Text("Not signed in")
                            .foregroundStyle(.rxInkSecondary)
                        Button("Sign In…") { openAccountSheet() }
                            .buttonStyle(.rx)
                    }
                }
            }
            if account.isLoggedIn {
                RXFormRow(
                    "Devices",
                    description: "Desktop devices on this account; add them as servers from the account panel."
                ) {
                    HStack(spacing: RX.Space.s3) {
                        Text(UURemoteAccountStore.deviceCount(account.desktopDevices.count))
                            .foregroundStyle(.rxInkSecondary)
                        Button("Refresh") {
                            Task { try? await account.refreshDevices() }
                        }
                        .buttonStyle(.rx)
                    }
                }
            }
        }
    }

    @MainActor
    private func openAccountSheet() {
        SheetPresenter.present { dismiss in
            UURemoteAccountSheet(onConnectDesktop: { machineID in
                dismiss()
                AppRouter.shared.openDesktop(machine: machineID)
            }, close: dismiss)
        }
    }
}

private struct AboutSettings: View {
    @State private var document: AboutDocument?

    var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        #if DEBUG
            return "\(short) (\(build)) · Debug"
        #else
            return "\(short) (\(build))"
        #endif
    }

    /// The commit this copy was built from, written in at build time.
    var commit: String {
        guard let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist"),
              let info = NSDictionary(contentsOf: url),
              let commit = info["GitCommit"] as? String, !commit.isEmpty
        else { return "Unknown" }
        return commit
    }

    var body: some View {
        RXDividedStack {
            RXFormRow("Version") {
                Text(version)
                    .font(.rxBody.monospacedDigit())
                    .foregroundStyle(.rxInkSecondary)
                    .textSelection(.enabled)
            }
            RXFormRow("Build", description: "The git commit this copy was built from; \"-dirty\" when the source had uncommitted changes.") {
                Text(commit)
                    .font(.rxCode)
                    .foregroundStyle(.rxInkSecondary)
                    .textSelection(.enabled)
            }
            RXFormRow("Source code", description: "mizorewww/catussh on GitHub") {
                Link(destination: URL(string: "https://github.com/mizorewww/catussh")!) {
                    Label("GitHub", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.rx)
            }
            RXFormRow("Report a problem", description: "Bugs and ideas go to the project's issue tracker.") {
                Link(destination: URL(string: "https://github.com/mizorewww/catussh/issues")!) {
                    Label("Issues", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.rx)
            }
            RXFormRow("Legal") {
                HStack(spacing: RX.Space.s2) {
                    Button("License…") { document = .license }
                        .buttonStyle(.rx)
                        .fixedSize()
                    Button("Agreement…") { document = .agreement }
                        .buttonStyle(.rx)
                        .fixedSize()
                        .help("End user license agreement")
                }
            }
        }
        .sheet(item: $document) { item in
            LicenseSheet(document: item) { document = nil }
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
            RXFormRow("Terminal", description: "Ghostty, its configuration catalog and app icon presets (MIT, Ghostty contributors).") {
                EmptyView()
            }
            RXFormRow("Libraries", description: "libssh2 · NSRemoteShell · Ghostty · Runestone · SymbolPicker · Keychain") {
                EmptyView()
            }
        }
    }
}

enum AboutDocument: String, Identifiable {
    case license = "LICENSE"
    case agreement = "EULA"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .license: return "License"
        case .agreement: return "End User License Agreement"
        }
    }

    var text: String {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: nil),
              let string = try? String(contentsOf: url, encoding: .utf8)
        else { return "The text could not be loaded." }
        return string
    }
}

struct LicenseSheet: View {
    let document: AboutDocument
    let close: () -> Void

    var body: some View {
        SheetScaffold(document.title) {
            ScrollView {
                Text(document.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.rxInkSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(RX.Space.s4)
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                    .strokeBorder(Color.rxHairline, lineWidth: 1)
            )
        } footer: {
            Spacer()
            Button("Done", action: close)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 600)
    }
}

/// First launch: the license in a scroll card, the agree checkbox, Quit and Continue.
struct AgreementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var agreed = false

    var body: some View {
        SheetScaffold("Welcome to catussh") {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                ScrollView {
                    Text(AboutDocument.agreement.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.rxInkSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(RX.Space.s4)
                }
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                        .strokeBorder(Color.rxHairline, lineWidth: 1)
                )
                Toggle("I have read and agree to the license", isOn: $agreed)
                    .rxCheckboxToggle()
                    .font(.rxBody)
            }
        } footer: {
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.rx)
            Spacer()
            Button("Continue") {
                CatusshStore.shared.licenseAgreed = true
                dismiss()
            }
            .buttonStyle(.rxPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(!agreed)
        }
        .frame(width: 560)
        .interactiveDismissDisabled()
    }
}

/// Manual backup export/import and OpenSSH `~/.ssh/config` importer under Settings -> General -> Data.
private struct DataBackupSettings: View {
    @EnvironmentObject var store: CatusshStore
    @State private var statusMessage: String?

    var body: some View {
        RXDividedStack {
            RXFormRow(
                "Backup archive",
                description: "Export or import all saved servers, identities, snippets, port forwards, and folders as a JSON backup file."
            ) {
                HStack(spacing: RX.Space.s2) {
                    Button("Export Backup…") {
                        exportBackup()
                    }
                    .buttonStyle(.rx)
                    Button("Import Backup…") {
                        importBackup()
                    }
                    .buttonStyle(.rx)
                }
            }
            RXFormRow(
                "OpenSSH config",
                description: "Import Host entries, IdentityFile keys, and ProxyJump links from ~/.ssh/config or another OpenSSH config file."
            ) {
                Button("Import ~/.ssh/config…") {
                    importSSHConfig()
                }
                .buttonStyle(.rx)
            }
            if let statusMessage {
                HelpText(statusMessage)
            }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "Export catussh Backup"
        panel.nameFieldStringValue = "catussh-backup.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportBackupData()
            try data.write(to: url, options: .atomic)
            statusMessage = "Exported backup to \(url.lastPathComponent)."
        } catch {
            UIBridge.presentError(with: "Could not export backup: \(error.localizedDescription)")
        }
    }

    private func importBackup() {
        UIBridge.openPanel(
            message: "Choose a catussh backup file (.json)",
            prompt: "Import",
            directory: nil,
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: false,
            canCreateDirectories: false,
            showsHiddenFiles: true
        ) { urls in
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                let result = try store.importBackupData(data)
                statusMessage = "Imported \(result.machines) servers, \(result.identities) identities, \(result.snippets) snippets, and \(result.forwards) port forwards."
            } catch {
                UIBridge.presentError(with: "Could not import backup: \(error.localizedDescription)")
            }
        }
    }

    private func importSSHConfig() {
        let sshDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        UIBridge.openPanel(
            message: "Choose an OpenSSH config file (e.g. ~/.ssh/config)",
            prompt: "Import",
            directory: sshDir,
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: false,
            canCreateDirectories: false,
            showsHiddenFiles: true
        ) { urls in
            guard let url = urls.first else { return }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                UIBridge.presentError(with: "Could not read \(url.lastPathComponent) as UTF-8 text.")
                return
            }
            let result = store.importOpenSSHConfig(text, baseDirectory: url.deletingLastPathComponent())
            statusMessage = "Imported \(result.importedServers) servers and \(result.importedIdentities) identities from \(url.lastPathComponent)."
        }
    }
}
