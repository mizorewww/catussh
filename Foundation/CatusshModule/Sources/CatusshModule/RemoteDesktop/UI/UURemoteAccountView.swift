//
//  UURemoteAccountView.swift
//  CatusshModule
//
//  The shared NetEase UU Remote account surface: QR / SMS / token sign-in,
//  the account's device list with "Add to Servers" / "Connect" actions,
//  a Remote Assistance quick-connect, and — on macOS — the local
//  `uuyc-cli` bridge to the installed official app.
//

import CatusshDesign
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// A reusable UU Remote account panel. Each host wraps it in its own
/// chrome (sheet on iOS / settings-style sheet on macOS) and passes
/// `onConnectDesktop` to route "Connect" into its session navigation;
/// when omitted the view only creates the session in
/// `RemoteDesktopManager`.
public struct UURemoteAccountView: View {
    @ObservedObject private var account = UURemoteAccountStore.shared
    /// Called with the machine id to open a desktop session on.
    public var onConnectDesktop: ((RDMachine.ID) -> Void)?

    @State private var loginMode: LoginMode = .qr
    @State private var phoneCountry = "+86"
    @State private var phoneNumber = ""
    @State private var smsCode = ""
    @State private var tokenDraft = ""
    @State private var assistID = ""
    @State private var assistCode = ""
    @State private var busyAction = ""
    @State private var infoLine = ""
    @State private var addedDeviceIDs: Set<String> = []

    public init(onConnectDesktop: ((RDMachine.ID) -> Void)? = nil) {
        self.onConnectDesktop = onConnectDesktop
    }

    enum LoginMode: String, CaseIterable {
        case qr = "QR Code"
        case sms = "SMS"
        case token = "Token"
    }

    public var body: some View {
        List {
            if account.isLoggedIn {
                accountSection
                devicesSection
                assistSection
                #if os(macOS)
                localAppSection
                #endif
            } else {
                loginSection
            }
            if !infoLine.isEmpty {
                Section {
                    Text(infoLine)
                        .font(.rxCaption)
                        .foregroundStyle(Color.rxInkSecondary)
                }
            }
        }
        .task {
            if account.isLoggedIn, account.devices.isEmpty {
                try? await account.refreshDevices()
            }
        }
    }

    // MARK: - Signed-in sections

    private var accountSection: some View {
        Section("Account") {
            HStack {
                Label(account.nickname.isEmpty ? "UU Remote user" : account.nickname,
                      systemImage: "person.crop.circle")
                Spacer()
                if !account.userID.isEmpty {
                    Text(account.userID)
                        .font(.rxCaption)
                        .foregroundStyle(Color.rxInkTertiary)
                }
            }
            Button("Sign Out", role: .destructive) {
                account.logout()
            }
        }
    }

    private var devicesSection: some View {
        Section {
            ForEach(account.desktopDevices, id: \.deviceID) { device in
                deviceRow(device)
            }
            if account.desktopDevices.isEmpty {
                Text("No desktop devices on this account")
                    .font(.rxCaption)
                    .foregroundStyle(Color.rxInkTertiary)
            }
        } header: {
            HStack {
                Text("Devices")
                Spacer()
                Button {
                    run("refreshing") { try await account.refreshDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(busyAction == "refreshing")
            }
        }
    }

    private func deviceRow(_ device: UUDeviceInfo) -> some View {
        HStack(spacing: 10) {
            StatusDot(device.isOnline ? .success : .off, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.alias.isEmpty ? device.deviceID : device.alias)
                    .lineLimit(1)
                Text("\(UUDeviceInfo.platformName(device.platform)) · \(device.deviceID)")
                    .font(.rxCaption)
                    .foregroundStyle(Color.rxInkTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if addedDeviceIDs.contains(device.deviceID) {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.rxSuccess)
            } else {
                Button("Add") { addToServers(device) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button("Connect") { connect(to: device) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!device.isOnline)
        }
    }

    private var assistSection: some View {
        Section {
            TextField("Connect ID (e.g. 123 456 789)", text: $assistID)
            SecureField("Verification code", text: $assistCode)
            Button("Connect to Assisted Device") { connectAssist() }
                .disabled(assistID.trimmingCharacters(in: .whitespaces).isEmpty || busyAction == "assist")
        } header: {
            Text("Remote Assistance")
        } footer: {
            Text("The Connect ID and code the other side shows in UU Remote's Remote Assistance.")
        }
    }

    #if os(macOS)
    private var localAppSection: some View {
        Section {
            if UULocalBridge.cliInstalled {
                ForEach(cliDevices) { entry in
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(entry.name)
                            .lineLimit(1)
                        Spacer()
                        Button("Open") {
                            try? UULocalBridge.cliConnect(deviceID: entry.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(entry.id.isEmpty)
                    }
                }
                if cliDevices.isEmpty {
                    Text("UURemote.app is installed; no devices reported by uuyc-cli.")
                        .font(.rxCaption)
                        .foregroundStyle(Color.rxInkTertiary)
                }
            } else {
                Text("Install UURemote.app to hand sessions off to the official client.")
                    .font(.rxCaption)
                    .foregroundStyle(Color.rxInkTertiary)
            }
        } header: {
            Text("Installed UU Remote App")
        }
    }

    /// Names + ids out of `uuyc-cli device list`; best-effort parsing —
    /// the CLI output is JSON of whatever shape the app build returns.
    private struct CLIDevice: Identifiable {
        let name: String
        let id: String
    }

    private var cliDevices: [CLIDevice] {
        guard let list = try? UULocalBridge.cliDeviceList() else { return [] }
        return list.compactMap { dict in
            let id = (dict["device_id"] ?? dict["deviceId"] ?? dict["id"] ?? "") as? String ?? ""
            let name = (dict["alias"] ?? dict["name"] ?? dict["device_name"] ?? id) as? String ?? id
            return name.isEmpty && id.isEmpty ? nil : CLIDevice(name: name, id: id)
        }
    }
    #endif

    // MARK: - Login section

    private var loginSection: some View {
        Section {
            Picker("Sign in with", selection: $loginMode) {
                ForEach(LoginMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch loginMode {
            case .qr: qrFields
            case .sms: smsFields
            case .token: tokenFields
            }

            if let error = account.loginError {
                Text(error)
                    .font(.rxCaption)
                    .foregroundStyle(Color.rxDanger)
            }
            if !account.qrStatusHint.isEmpty, loginMode != .qr {
                Text(account.qrStatusHint)
                    .font(.rxCaption)
                    .foregroundStyle(Color.rxInkSecondary)
            }
        } header: {
            Text("Sign In to NetEase UU Remote")
        }
    }

    private var qrFields: some View {
        VStack(alignment: .center, spacing: 10) {
            if let data = account.qrImageData, let image = RemoteDesktopImage(data: data) {
                Image(rxImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.rxSurfaceSunken)
                    .frame(width: 200, height: 200)
                    .overlay {
                        if busyAction == "qr" { ProgressView() }
                        else { Text("No QR code").font(.rxCaption).foregroundStyle(Color.rxInkTertiary) }
                    }
            }
            Text(account.qrStatusHint.isEmpty
                 ? "Generate a code and scan it with the UU Remote mobile app."
                 : account.qrStatusHint)
                .font(.rxCaption)
                .foregroundStyle(Color.rxInkSecondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Generate QR Code") {
                    run("qr") { _ = try await account.startQRLogin() }
                }
                .disabled(busyAction == "qr")
                if account.qrLoginState == .expired {
                    Text("(expired — generate a new one)")
                        .font(.rxCaption)
                        .foregroundStyle(Color.rxWarning)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var smsFields: some View {
        Group {
            HStack {
                TextField("+86", text: $phoneCountry)
                    .frame(width: 70)
                TextField("Phone number", text: $phoneNumber)
                    #if os(iOS)
                    .keyboardType(.phonePad)
                    #endif
            }
            Button(busyAction == "sms-send" ? "Sending…" : "Send Code") {
                run("sms-send") {
                    try await account.sendSMSCode(countryCode: phoneCountry, mobile: phoneNumber)
                }
            }
            .disabled(phoneNumber.isEmpty || busyAction == "sms-send")
            HStack {
                TextField("SMS code", text: $smsCode)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("Sign In") {
                    run("sms-login") {
                        try await account.loginBySMS(countryCode: phoneCountry, mobile: phoneNumber, code: smsCode)
                    }
                }
                .disabled(smsCode.isEmpty || busyAction == "sms-login")
            }
        }
    }

    private var tokenFields: some View {
        Group {
            SecureField("Access token", text: $tokenDraft)
            Button("Import Token") {
                run("token") { try await account.importToken(tokenDraft) }
            }
            .disabled(tokenDraft.isEmpty || busyAction == "token")
            Text("Grab the token from a logged-in UU Remote client (`nrd_access_token`).")
                .font(.rxCaption)
                .foregroundStyle(Color.rxInkTertiary)
        }
    }

    // MARK: - Actions

    private func run(_ tag: String, _ work: @escaping () async throws -> Void) {
        busyAction = tag
        infoLine = ""
        Task { @MainActor in
            defer { busyAction = "" }
            do {
                try await work()
            } catch {
                infoLine = error.localizedDescription
            }
        }
    }

    private func addToServers(_ device: UUDeviceInfo) {
        let machine = account.makeMachine(for: device)
        CatusshStore.shared.machineGroup.insert(machine)
        addedDeviceIDs.insert(device.deviceID)
        infoLine = "Added \"\(machine.name)\" to Servers."
    }

    private func connect(to device: UUDeviceInfo) {
        let machine = upsertMachine(account.makeMachine(for: device))
        openDesktop(on: machine)
    }

    private func connectAssist() {
        let id = assistID.replacingOccurrences(of: " ", with: "")
        var machine = RDMachine(
            remoteAddress: id,
            remotePort: "22",
            name: "Assist \(id)",
            group: "UU Remote",
            comment: "UU Remote assistance session"
        )
        machine.remoteDesktopProtocol = .uuRemote
        machine.transport = .uuRemote
        machine.uuAssistID = id
        machine.uuAssistCode = assistCode
        machine = upsertMachine(machine)
        openDesktop(on: machine)
    }

    /// Inserts the machine into the store, or reuses an existing machine
    /// already bound to the same UU device / assist id.
    private func upsertMachine(_ machine: RDMachine) -> RDMachine {
        let store = CatusshStore.shared
        if !machine.uuDeviceID.isEmpty,
           let existing = store.machineGroup.machines.first(where: { $0.uuDeviceID == machine.uuDeviceID })
        {
            return existing
        }
        if !machine.uuAssistID.isEmpty,
           let existing = store.machineGroup.machines.first(where: { $0.uuAssistID == machine.uuAssistID })
        {
            return existing
        }
        store.machineGroup.insert(machine)
        return machine
    }

    private func openDesktop(on machine: RDMachine) {
        if let onConnectDesktop {
            onConnectDesktop(machine.id)
        } else {
            RemoteDesktopManager.shared.begin(for: machine.id)
        }
    }
}

/// Platform image alias for QR-code data.
#if canImport(UIKit)
    typealias RemoteDesktopImage = UIImage
    private extension Image {
        init(rxImage: RemoteDesktopImage) { self.init(uiImage: rxImage) }
    }
#elseif canImport(AppKit)
    typealias RemoteDesktopImage = NSImage
    private extension Image {
        init(rxImage: RemoteDesktopImage) { self.init(nsImage: rxImage) }
    }
#endif
