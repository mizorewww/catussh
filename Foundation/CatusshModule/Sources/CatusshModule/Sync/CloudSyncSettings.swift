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
    @State private var confirmsDelete = false

    public init() {}

    public var body: some View {
        RXDividedStack {
            // A build that cannot sync says so beside the switch, on or off:
            // on, it can only be turned off.
            RXFormRow("Sync with iCloud", description: sync.problem.map { sync.isOn ? $0 + " Turn this off; nothing is synced." : $0 } ?? """
            Servers and identities are encrypted on this device, with a passphrase you choose, \
            before they go to iCloud. Apple cannot read them.
            """) {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { sync.isOn },
                    set: { on in
                        if on {
                            asking = sync.hasStoredData ? .enter : .create
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
                    .disabled(sync.problem != nil && !sync.isOn)
            }
            if sync.isOn {
                RXFormRow("Status", description: statusText) {
                    HStack(spacing: RX.Space.s2) {
                        switch sync.status {
                        case .locked:
                            Button("Enter Passphrase…") { asking = .enter }
                                .buttonStyle(.rx(size: .small))
                            Button("Replace…") { asking = .change }
                                .buttonStyle(.rx(size: .small))
                        case .unreadable:
                            Button("Replace…") { asking = .change }
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
                SwitchRow("Servers", description: "Addresses, names, groups and comments.", isOn: $sync.syncsServers)
                SwitchRow(
                    "Identities",
                    description: "User names, passwords and private keys.",
                    isOn: $sync.syncsIdentities
                )
                RXFormRow("Passphrase", description: "After a change, your other devices ask for the new one.") {
                    Button("Change…") { asking = .change }
                        .buttonStyle(.rx(size: .small))
                }
                RXFormRow("Data in iCloud", description: "Remove it and stop syncing on this device.") {
                    Button("Delete…") { confirmsDelete = true }
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
        .alert("Delete what catussh keeps in iCloud?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { sync.deleteStoredData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
            Your servers and identities stay on this device. A device that still syncs will store \
            its own again, so turn sync off there too.
            """)
        }
    }

    private var statusText: String {
        switch sync.status {
        case .off: return ""
        case let .unavailable(reason): return reason
        case .syncing: return "Syncing…"
        case let .synced(date):
            return "Up to date. Last synced at \(date.formatted(date: .omitted, time: .shortened))."
        case .locked:
            return """
            The passphrase on this device does not open what is in iCloud. Enter the one your \
            other device uses, or replace what is stored with this device's data.
            """
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
            It encrypts your servers and identities before they leave this device. You will \
            enter it once on each of your devices. It cannot be recovered if you forget it.
            """
        case .enter:
            return "iCloud already holds data from one of your devices. Enter the passphrase you chose there."
        case .change:
            return """
            What is in iCloud is replaced with this device's servers and identities, encrypted \
            with the new passphrase. Your other devices will ask for it.
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
