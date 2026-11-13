//
//  CloudSyncSettings.swift
//  CatusshModule
//
//  The rows of Settings › General › iCloud Sync, the same on the Mac and on iOS.
//

import CatusshDesign
import SwiftUI

public struct CloudSyncSettings: View {
    @ObservedObject private var sync = CloudSync.shared
    @State private var asking: PassphraseSheet.Purpose?
    @State private var confirming: Confirmation?

    public init() {}

    /// What an alert asks before it is done.
    private enum Confirmation: Identifiable {
        /// Delete what is in iCloud.
        case delete
        /// Make a new key in iCloud Keychain.
        case resetKey
        /// Put this device's data in place of what is in iCloud, under a new key.
        case replace

        var id: Self { self }
    }

    public var body: some View {
        RXDividedStack {
            // A build that cannot sync shows the switch off and out of reach,
            // whatever was chosen in a build that could, and nothing more.
            RXFormRow("Sync with iCloud", description: sync.problem ?? lead) {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { sync.isOn && sync.problem == nil },
                    set: { on in
                        if on {
                            // Without iCloud Keychain, a passphrase.
                            if !sync.turnOn() { asking = sync.hasStoredData ? .enter : .create }
                        } else {
                            sync.turnOff()
                        }
                    }
                ))
                .labelsHidden()
                .rxSwitchToggle()
                .tint(.rxAccent)
                #if os(macOS) || targetEnvironment(macCatalyst)
                    .controlSize(.small)
                #endif
                    .disabled(sync.problem != nil)
            }
            if sync.isOn, sync.problem == nil {
                RXFormRow("Status", description: statusText) {
                    HStack(spacing: RX.Space.s2) {
                        switch sync.status {
                        case .locked:
                            Button("Enter Passphrase…") { asking = .enter }
                                .buttonStyle(.rx(size: .small))
                            Button("Replace…", action: replace)
                                .buttonStyle(.rx(size: .small))
                        case .needsPassphrase:
                            Button("Choose Passphrase…") { asking = sync.hasStoredData ? .enter : .create }
                                .buttonStyle(.rx(size: .small))
                        case .waitingForKey:
                            Button("Check Again") { sync.sync() }
                                .buttonStyle(.rx(size: .small))
                            Button("Replace…", action: replace)
                                .buttonStyle(.rx(size: .small))
                        case .unreadable:
                            Button("Replace…", action: replace)
                                .buttonStyle(.rx(size: .small))
                        case .unavailable, .off:
                            EmptyView()
                        case .syncing, .synced, .failed:
                            Button("Sync Now") { sync.sync() }
                                .buttonStyle(.rx(size: .small))
                                .disabled(sync.status == .syncing)
                        }
                    }
                }
                SwitchRow("Servers", description: "Addresses, names, folders and comments.", isOn: $sync.syncsServers)
                SwitchRow(
                    "Identities",
                    description: "User names, passwords and private keys.",
                    isOn: $sync.syncsIdentities
                )
                SwitchRow("Snippets", description: "Commands, their names and groups.", isOn: $sync.syncsSnippets)
                #if os(macOS)
                    // Port forwarding is a Mac feature; iPhone and iPad
                    // carry the Mac's forwards along untouched.
                    SwitchRow(
                        "Port forwards",
                        description: "Local, remote and SOCKS forwards.",
                        isOn: $sync.syncsPortForwards
                    )
                #endif
                SwitchRow(
                    "Settings",
                    description: "Appearance, sessions, recent servers, SSH, monitor and terminal settings.",
                    isOn: $sync.syncsSettings
                )
                if sync.usesKeychain {
                    RXFormRow(
                        "Encryption key",
                        description: "Kept in iCloud Keychain. A new one replaces it on your other devices too."
                    ) {
                        Button("Reset…") { confirming = .resetKey }
                            .buttonStyle(.rx(size: .small))
                    }
                } else {
                    RXFormRow("Passphrase", description: "After a change, your other devices ask for the new one.") {
                        Button("Change…") { asking = .change }
                            .buttonStyle(.rx(size: .small))
                    }
                }
                RXFormRow("Data in iCloud", description: "Remove it and stop syncing on this device.") {
                    Button("Delete…") { confirming = .delete }
                        .buttonStyle(.rx(size: .small))
                }
            }
        }
        .sheet(item: $asking) { purpose in
            PassphraseSheet(purpose: purpose) { passphrase in
                switch purpose {
                case .create, .enter: sync.turnOn(passphrase: passphrase)
                case .change: sync.replaceStoredData(passphrase: passphrase)
                }
            }
        }
        .alert(
            alertTitle,
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { confirmation in
            switch confirmation {
            case .delete:
                Button("Delete", role: .destructive) { sync.deleteStoredData() }
            case .resetKey:
                Button("Reset", role: .destructive) { sync.resetKey() }
            case .replace:
                Button("Replace", role: .destructive) { sync.replaceStoredData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            switch confirmation {
            case .delete:
                Text(sync.usesKeychain ? """
                Your data stays on this device; the key in iCloud Keychain is removed. A device that \
                still syncs will store its own again, so turn sync off there too.
                """ : """
                Your data stays on this device. A device that still syncs will store its own again, \
                so turn sync off there too.
                """)
            case .resetKey:
                Text("""
                What is in iCloud is encrypted again with a new key. Your other devices go on syncing \
                once iCloud Keychain brings it to them.
                """)
            case .replace:
                Text("""
                What is in iCloud is replaced with this device's data, encrypted with a new key. Your \
                other devices add theirs once iCloud Keychain brings them the key.
                """)
            }
        }
    }

    private var lead: String {
        if sync.usesKeychain {
            return """
            Servers, identities, snippets, port forwards and settings are encrypted on this device \
            before they go to iCloud. The key is kept in iCloud Keychain, so your other devices need \
            nothing more. Apple cannot read them.
            """
        }
        return """
        Servers, identities, snippets, port forwards and settings are encrypted on this device, with \
        a passphrase you choose, before they go to iCloud. Apple cannot read them.
        """
    }

    private var alertTitle: String {
        switch confirming {
        case .delete, nil: return "Delete what catussh keeps in iCloud?"
        case .resetKey: return "Make a new encryption key?"
        case .replace: return "Replace what is in iCloud?"
        }
    }

    /// With iCloud Keychain, under a new key; without, under a new passphrase.
    private func replace() {
        if sync.usesKeychain {
            confirming = .replace
        } else {
            asking = .change
        }
    }

    private var statusText: String {
        switch sync.status {
        case .off: return ""
        case let .unavailable(reason): return reason
        case .syncing: return "Syncing…"
        case let .synced(date):
            return "Up to date. Last synced at \(date.formatted(date: .omitted, time: .shortened))."
        case .waitingForKey:
            if sync.usesKeychain {
                return """
                Waiting for the key from iCloud Keychain… It comes from the device that turned sync on \
                first, which can take a few minutes. Make sure iCloud Keychain (Passwords & Keychain in \
                your Apple Account settings) is on, on this device and on that one.
                """
            }
            return """
            What is in iCloud is encrypted with a key kept in iCloud Keychain, which catussh cannot \
            use on this device. Replace it with this device's data, under a passphrase, to go on.
            """
        case .locked:
            return """
            What is in iCloud is encrypted with a passphrase, chosen on another device or in an \
            earlier version of catussh. Enter it once, or replace what is stored with this device's data.
            """
        case .needsPassphrase:
            return "iCloud Keychain is not available here, so sync needs a passphrase to encrypt your data."
        case .unreadable:
            return "What is in iCloud cannot be read. Replace it with this device's data to go on."
        case let .failed(reason): return reason
        }
    }
}

private struct PassphraseSheet: View {
    enum Purpose: String, Identifiable {
        /// The first device: choose a passphrase.
        case create
        /// Another device stored data already: give its passphrase.
        case enter
        /// Choose a new passphrase and store this device's data under it.
        case change

        var id: String { rawValue }
    }

    let purpose: Purpose
    let done: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var again = ""
    @FocusState private var focused: Bool

    private var chooses: Bool { purpose != .enter }

    private var problem: String? {
        guard chooses else { return nil }
        if passphrase.isEmpty { return nil }
        if passphrase.count < CloudSync.minimumPassphraseLength {
            return "At least \(CloudSync.minimumPassphraseLength) characters."
        }
        if !again.isEmpty, again != passphrase { return "The two do not match." }
        return nil
    }

    private var ready: Bool {
        if chooses {
            return passphrase.count >= CloudSync.minimumPassphraseLength && again == passphrase
        }
        return !passphrase.isEmpty
    }

    private var title: String {
        switch purpose {
        case .create: return "Choose a Passphrase"
        case .enter: return "Enter Your Passphrase"
        case .change: return "Choose a New Passphrase"
        }
    }

    private var lead: String {
        switch purpose {
        case .create:
            return """
            iCloud Keychain is not available here, so a passphrase encrypts your data before it \
            leaves this device. You will enter it once on each of your devices. It cannot be \
            recovered if you forget it.
            """
        case .enter:
            return "iCloud already holds data from one of your devices. Enter the passphrase you chose there."
        case .change:
            return """
            What is in iCloud is replaced with this device's data, encrypted with the new \
            passphrase. Your other devices will ask for it.
            """
        }
    }

    var body: some View {
        SheetScaffold(title, lead: lead) {
            VStack(alignment: .leading, spacing: RX.Space.s4) {
                RXField("Passphrase", error: chooses ? nil : problem) {
                    SecureField("", text: $passphrase)
                        .textFieldStyle(.rx)
                        .focused($focused)
                        .onSubmit(submit)
                }
                if chooses {
                    RXField("Again", error: problem) {
                        SecureField("", text: $again)
                            .textFieldStyle(.rx)
                            .onSubmit(submit)
                    }
                }
            }
        } footer: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(purpose == .change ? "Replace" : "Turn On", action: submit)
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
        }
        #if targetEnvironment(macCatalyst) || os(macOS)
        .frame(width: 440)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        #endif
        .onAppear { focused = true }
    }

    private func submit() {
        guard ready else { return }
        done(passphrase)
        dismiss()
    }
}
