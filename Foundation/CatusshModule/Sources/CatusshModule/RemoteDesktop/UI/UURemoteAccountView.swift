//
//  UURemoteAccountView.swift
//  CatusshModule
//
//  The shared NetEase UU Remote account surface: QR / SMS / token sign-in,
//  then the account, its devices (servers in the account's folder) and a
//  Remote Assistance quick-connect.
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

    public init(onConnectDesktop: ((RDMachine.ID) -> Void)? = nil) {
        self.onConnectDesktop = onConnectDesktop
    }

    enum LoginMode: String, CaseIterable {
        case qr = "QR Code"
        case sms = "SMS"
        case token = "Token"
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RX.Space.s4) {
                if account.isLoggedIn {
                    accountCard
                    devicesCard
                    assistCard
                } else {
                    signInCard
                }
                if !infoLine.isEmpty {
                    Text(infoLine)
                        .font(.rxHelp)
                        .foregroundStyle(Color.rxInkSecondary)
                }
            }
            .padding(RX.Space.s4)
        }
        .task(id: account.isLoggedIn) {
            if account.isLoggedIn, account.devices.isEmpty {
                try? await account.refreshDevices()
            }
        }
    }

    // MARK: - Signed in

    private var accountCard: some View {
        HStack(spacing: RX.Space.s3) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color.rxAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.nickname.isEmpty ? "UU Remote account" : account.nickname)
                    .font(.rxBodyStrong)
                    .foregroundStyle(Color.rxInk)
                Text(account.userID.isEmpty ? "Signed in" : "ID \(account.userID)")
                    .font(.rxHelp)
                    .foregroundStyle(Color.rxInkSecondary)
            }
            Spacer()
            Button("Sign Out", role: .destructive) { account.logout() }
                .buttonStyle(.rx(.plain))
        }
        .rxCard()
    }

    /// The devices, which are servers in the account's folder.
    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            HStack {
                CardHead("Devices")
                Spacer()
                Button {
                    run("refreshing") { try await account.refreshDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.rx(.plain, size: .small))
                .disabled(busyAction == "refreshing")
            }
            Text("They are servers in the \"\(account.folder()?.name ?? "UU Remote")\" folder, kept up to date with the account.")
                .font(.rxHelp)
                .foregroundStyle(Color.rxInkSecondary)
            ForEach(account.desktopDevices, id: \.deviceID) { device in
                deviceRow(device)
            }
            if account.desktopDevices.isEmpty {
                Text("No desktop devices on this account yet. Install UU Remote on a computer and sign in there with the same account.")
                    .font(.rxHelp)
                    .foregroundStyle(Color.rxInkTertiary)
            }
        }
        .rxCard()
    }

    private func deviceRow(_ device: UUDeviceInfo) -> some View {
        HStack(spacing: RX.Space.s3) {
            StatusDot(device.isOnline ? .success : .off, size: .small)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.alias.isEmpty ? device.deviceID : device.alias)
                    .font(.rxBody)
                    .foregroundStyle(Color.rxInk)
                    .lineLimit(1)
                Text("\(UUDeviceInfo.platformName(device.platform)) · \(device.isOnline ? "Online" : "Offline")")
                    .font(.rxHelp)
                    .foregroundStyle(Color.rxInkSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Desktop") { connect(to: device) }
                .buttonStyle(.rx(size: .small))
                .disabled(!device.isOnline)
        }
        .frame(minHeight: 36)
    }

    private var assistCard: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            CardHead("Remote Assistance")
            Text("Join someone's screen with the Connect ID and code their UU Remote shows.")
                .font(.rxHelp)
                .foregroundStyle(Color.rxInkSecondary)
            HStack(spacing: RX.Space.s2) {
                TextField("Connect ID", text: $assistID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Code", text: $assistCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Button("Join") { connectAssist() }
                    .buttonStyle(.rx)
                    .disabled(assistID.trimmingCharacters(in: .whitespaces).isEmpty || busyAction == "assist")
            }
        }
        .rxCard()
    }

    // MARK: - Signing in

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: RX.Space.s4) {
            // The host's chrome names UU Remote; this says what signing in does.
            Text("Sign in, and the account's computers appear as servers in a folder of their own, kept up to date.")
                .font(.rxBody)
                .foregroundStyle(Color.rxInkSecondary)
            Picker("Sign in with", selection: $loginMode) {
                ForEach(LoginMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch loginMode {
            case .qr: qrFields
            case .sms: smsFields
            case .token: tokenFields
            }
            if let error = account.loginError {
                Text(error)
                    .font(.rxHelp)
                    .foregroundStyle(Color.rxDanger)
            }
        }
        .rxCard()
    }

    /// The code is made as soon as it is shown, and made again when it expires.
    private var qrFields: some View {
        HStack(alignment: .top, spacing: RX.Space.s5) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                if let data = account.qrImageData, let image = RemoteDesktopImage(data: data) {
                    Image(rxImage: image)
                        .resizable()
                        .interpolation(.none)
                        .padding(10)
                        .opacity(account.qrLoginState == .expired ? 0.15 : 1)
                } else {
                    ProgressView()
                }
                if account.qrLoginState == .expired {
                    Button("Refresh Code") { generateQR() }
                        .buttonStyle(.rxPrimary)
                }
            }
            .frame(width: 180, height: 180)
            VStack(alignment: .leading, spacing: RX.Space.s2) {
                step(1, "Open UU Remote on your phone.")
                step(2, "Tap Scan, and point it at this code.")
                step(3, "Confirm the sign-in on the phone.")
                Spacer(minLength: RX.Space.s2)
                HStack(spacing: RX.Space.s2) {
                    if account.qrLoginState == .scanned || account.qrLoginState == .confirmed {
                        ProgressView().controlSize(.small)
                    }
                    Text(qrStatus)
                        .font(.rxHelp)
                        .foregroundStyle(Color.rxInkSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        }
        .onAppear {
            if account.qrImageData == nil || account.qrLoginState == .idle { generateQR() }
        }
    }

    private var qrStatus: String {
        switch account.qrLoginState {
        case .idle, .generating: "Making a code…"
        case .waiting: "Waiting for the scan."
        case .scanned: "Scanned. Confirm on the phone."
        case .confirmed: "Signing in…"
        case .expired: "The code expired."
        case let .failed(reason): reason
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RX.Space.s2) {
            Text("\(number)")
                .font(.rxHelp.weight(.semibold))
                .foregroundStyle(Color.rxOnAccent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.rxAccent))
            Text(text)
                .font(.rxBody)
                .foregroundStyle(Color.rxInk)
        }
    }

    private func generateQR() {
        run("qr") { _ = try await account.startQRLogin() }
    }

    private var smsFields: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            HStack(spacing: RX.Space.s2) {
                TextField("+86", text: $phoneCountry)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                TextField("Phone number", text: $phoneNumber)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.phonePad)
                    #endif
                Button(busyAction == "sms-send" ? "Sending…" : "Send Code") {
                    run("sms-send") {
                        try await account.sendSMSCode(countryCode: phoneCountry, mobile: phoneNumber)
                        infoLine = "A code was sent to \(phoneCountry) \(phoneNumber)."
                    }
                }
                .buttonStyle(.rx)
                .disabled(phoneNumber.isEmpty || busyAction == "sms-send")
            }
            HStack(spacing: RX.Space.s2) {
                TextField("Code from the SMS", text: $smsCode)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Button("Sign In") {
                    run("sms-login") {
                        try await account.loginBySMS(countryCode: phoneCountry, mobile: phoneNumber, code: smsCode)
                    }
                }
                .buttonStyle(.rxPrimary)
                .disabled(smsCode.isEmpty || busyAction == "sms-login")
            }
        }
    }

    private var tokenFields: some View {
        VStack(alignment: .leading, spacing: RX.Space.s2) {
            HStack(spacing: RX.Space.s2) {
                SecureField("Access token", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Sign In") {
                    run("token") { try await account.importToken(tokenDraft) }
                }
                .buttonStyle(.rxPrimary)
                .disabled(tokenDraft.isEmpty || busyAction == "token")
            }
            Text("For an access token you already have; most people sign in with the QR code.")
                .font(.rxHelp)
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

    private func connect(to device: UUDeviceInfo) {
        openDesktop(on: account.upsertMachine(for: device))
    }

    private func connectAssist() {
        let id = assistID.replacingOccurrences(of: " ", with: "")
        var machine = RDMachine(
            remoteAddress: id,
            remotePort: "22",
            name: "Assist \(id)",
            // Not the account's folder: a refresh would treat it as a device.
            group: "",
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
