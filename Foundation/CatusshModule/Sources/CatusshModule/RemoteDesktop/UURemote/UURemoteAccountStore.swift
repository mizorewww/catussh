//
//  UURemoteAccountStore.swift
//  CatusshModule
//
//  Observable state store for the signed-in UU Remote account, persisted the
//  same way CatusshStore keeps its secrets (AES-encrypted UserDefaults). Handles
//  QR/SMS/token login, device discovery, and one-click RDMachine binding.
//

import Combine
import CoreImage
import CryptoKit
import Foundation
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
public final class UURemoteAccountStore: ObservableObject {
    public static let shared = UURemoteAccountStore()

    @Published public private(set) var credentials = UUCredentials()
    @Published public private(set) var userID = ""
    @Published public private(set) var nickname = ""
    @Published public private(set) var devices: [UUDeviceInfo] = []
    @Published public private(set) var qrLoginState = QRLoginState.idle
    @Published public private(set) var qrImageData: Data?
    @Published public private(set) var qrStatusHint = ""
    @Published public private(set) var loginError: String?
    @Published public private(set) var isLoggedIn = false

    private let client = UURemoteAPIClient()
    private var qrPollingTask: Task<Void, Never>?
    private var qrSession: (token: String, jumpURL: String)?

    public enum QRLoginState: Equatable {
        case idle
        case generating
        case waiting
        case scanned
        case confirmed
        case expired
        case failed(String)
    }

    private init() {
        loadPersisted()
    }

    // MARK: - Persistence

    private static let persistedKey = "me.mizorewww.rayon.uuremote.account"

    private func loadPersisted() {
        guard let encrypted = UserDefaults.standard.data(forKey: Self.persistedKey),
              let decrypted = AES.shared.decrypt(data: encrypted),
              let saved = try? JSONDecoder().decode(UUCredentials.self, from: decrypted)
        else { return }
        credentials = saved
        userID = saved.userID
        isLoggedIn = saved.isComplete
        Task {
            await client.updateCredentials(saved)
            // Credentials saved by an older version may lack the device
            // identity; complete it so `isComplete` reflects the token.
            await ensureLocalDeviceIdentity()
            if !credentials.token.isEmpty {
                isLoggedIn = credentials.isComplete
            }
        }
    }

    private func persist() {
        var toSave = credentials
        toSave.userID = userID
        guard let data = try? JSONEncoder().encode(toSave),
              let encrypted = AES.shared.encrypt(data: data)
        else { return }
        UserDefaults.standard.set(encrypted, forKey: Self.persistedKey)
    }

    // MARK: - Login

    /// Starts a QR-code login session and returns the QR content to render.
    public func startQRLogin() async throws -> String {
        qrPollingTask?.cancel()
        qrLoginState = .generating
        qrStatusHint = "Generating QR code…"
        do {
            try await ensureRegisteredDevice()
            let (jumpURL, token, ticket) = try await client.qrcodeGenLogin()
            qrSession = (token, jumpURL)
            qrImageData = Self.makeQRCode(content: jumpURL)
            qrLoginState = .waiting
            qrStatusHint = "Scan with the UU Remote app"
            qrPollingTask = Task { await pollQRLogin(token: token, jumpURL: jumpURL, ticket: ticket) }
            return jumpURL
        } catch {
            qrLoginState = .failed(error.localizedDescription)
            qrStatusHint = error.localizedDescription
            loginError = error.localizedDescription
            throw error
        }
    }

    private func pollQRLogin(token: String, jumpURL: String, ticket: String) async {
        var lastStatus = 1
        while !Task.isCancelled {
            do {
                let status = try await client.qrcodeLoginStatus(token: token, qrcodeJumpURL: jumpURL, loginStatus: lastStatus)
                switch status {
                case 0:
                    qrLoginState = .expired
                    qrStatusHint = "QR code expired"
                    return
                case 1:
                    qrStatusHint = "Scan with the UU Remote app"
                case 2:
                    qrStatusHint = "Scanned — confirm on the device"
                    qrLoginState = .scanned
                case 3:
                    continue
                case 4:
                    qrLoginState = .confirmed
                    qrStatusHint = "Logging in…"
                    try await finishQRLogin(token: token, jumpURL: jumpURL)
                    return
                default:
                    qrStatusHint = "Waiting…"
                }
                lastStatus = status
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                if !Task.isCancelled {
                    qrStatusHint = error.localizedDescription
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }
    }

    private func finishQRLogin(token: String, jumpURL: String) async throws {
        let (uid, nick, jwt) = try await client.loginByQRCode(token: token, qrcodeJumpURL: jumpURL)
        await applyLoginCredentials(userID: uid, nickname: nick, token: jwt)
        qrStatusHint = "Logged in as \(nickname.isEmpty ? userID : nickname)"
    }

    /// Sends an SMS verification code to a phone number.
    public func sendSMSCode(countryCode: String, mobile: String) async throws {
        try await ensureRegisteredDevice()
        try await client.mobileCode(countryCode: countryCode, mobile: mobile)
    }

    /// Logs in with an SMS verification code.
    public func loginBySMS(countryCode: String, mobile: String, code: String) async throws {
        let (uid, nick, jwt) = try await client.loginByMobile(countryCode: countryCode, mobile: mobile, code: code)
        await applyLoginCredentials(userID: uid, nickname: nick, token: jwt)
    }

    /// Imports a token directly (for users who copied it from a client).
    public func importToken(_ token: String, userID: String = "", deviceID: String = "", clientID: String = "", systemID: String = "") async throws {
        var creds = credentials
        creds.token = token
        creds.userID = userID
        creds.csrf = UURequestSigner.csrf(from: token) ?? ""
        creds.deviceID = deviceID
        creds.clientID = clientID
        creds.systemID = systemID
        credentials = creds
        // Token imports arrive without a login response; read the account
        // id out of the JWT claims when the caller did not supply one.
        if creds.userID.isEmpty {
            creds.userID = UURequestSigner.userID(from: token) ?? ""
        }
        self.userID = creds.userID
        persist()
        await client.updateCredentials(creds)
        await ensureLocalDeviceIdentity()
        isLoggedIn = credentials.isComplete
        try? await refreshDevices()
    }

    /// Stores a freshly acquired token, fills the missing identity fields,
    /// registers this machine as a UU device, and lands `isLoggedIn` once
    /// `isComplete` holds.
    private func applyLoginCredentials(userID uid: String, nickname nick: String, token jwt: String) async {
        var creds = credentials
        creds.token = jwt
        creds.userID = uid.isEmpty ? (UURequestSigner.userID(from: jwt) ?? "") : uid
        creds.csrf = UURequestSigner.csrf(from: jwt) ?? ""
        credentials = creds
        userID = creds.userID
        nickname = nick
        persist()
        await client.updateCredentials(creds)
        await ensureLocalDeviceIdentity()
        isLoggedIn = credentials.isComplete
        // The account's folder fills as soon as there is an account.
        try? await refreshDevices()
    }

    /// Guarantees `clientID`/`systemID`/`deviceID` exist: the ids are
    /// generated once and persisted, and the device id comes from
    /// `/api/v1/device/windows/init` (or a deterministic local fallback when
    /// registration is unreachable, so `isComplete` still reflects a valid
    /// token).
    private func ensureLocalDeviceIdentity() async {
        var creds = credentials
        var changed = false
        if creds.clientID.isEmpty { creds.clientID = UUID().uuidString; changed = true }
        if creds.systemID.isEmpty { creds.systemID = UUID().uuidString; changed = true }
        if changed {
            credentials = creds
            persist()
            await client.updateCredentials(creds)
        }
        guard creds.deviceID.isEmpty, !creds.token.isEmpty else { return }
        do {
            _ = try await registerLocalDevice(name: Self.localDeviceName)
        } catch {
            var updated = credentials
            guard updated.deviceID.isEmpty else { return }
            updated.deviceID = Self.deterministicDeviceID(clientID: updated.clientID, systemID: updated.systemID)
            credentials = updated
            persist()
            await client.updateCredentials(updated)
        }
    }

    /// Login requests are signed as a registered device: without a device id
    /// the service refuses to make a QR code or send an SMS code. The device
    /// is registered once, before the first login, and kept.
    private func ensureRegisteredDevice() async throws {
        await ensureLocalDeviceIdentity()
        guard credentials.deviceID.isEmpty else { return }
        _ = try await registerLocalDevice(name: Self.localDeviceName)
    }

    /// A stable 16-character lowercase-alphanumeric device id derived from
    /// the persisted client/system ids — deterministic across launches, so
    /// the server sees the same pseudo-device every time.
    nonisolated static func deterministicDeviceID(clientID: String, systemID: String) -> String {
        let digest = SHA256.hash(data: Data("uu|\(clientID)|\(systemID)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// The device name registration reports, mirroring how the official
    /// client names the host machine.
    nonisolated static var localDeviceName: String {
        ProcessInfo.processInfo.hostName.components(separatedBy: ".").first.flatMap {
            $0.isEmpty ? nil : $0
        } ?? "catussh"
    }

    /// Signs out and clears the account. The device catussh registered as is
    /// kept, so signing in again does not add another one to the service.
    public func logout() {
        qrPollingTask?.cancel()
        qrSession = nil
        var kept = UUCredentials()
        kept.clientID = credentials.clientID
        kept.systemID = credentials.systemID
        kept.deviceID = credentials.deviceID
        credentials = kept
        userID = ""
        nickname = ""
        devices = []
        isLoggedIn = false
        qrLoginState = .idle
        qrImageData = nil
        qrStatusHint = ""
        persist()
        Task { await client.updateCredentials(kept) }
    }

    // MARK: - Devices

    /// Refreshes the account's device list and the folder that shows it.
    public func refreshDevices() async throws {
        let list = try await client.deviceGroupsOfMy()
        if list.isEmpty {
            devices = try await client.deviceList()
        } else {
            devices = list
        }
        syncFolder()
    }

    /// The folder this account's devices are in, if it was made.
    public func folder(store: CatusshStore = .shared) -> RDFolder? {
        guard !userID.isEmpty else { return nil }
        return store.folderGroup.folders.first { $0.source == .uuRemote(userID: userID) }
    }

    /// Puts the devices in the account's folder, making the folder the first
    /// time.
    public func syncFolder(store: CatusshStore = .shared) {
        guard isLoggedIn, !userID.isEmpty else { return }
        let folder = folder(store: store) ?? adoptOrCreateFolder(store: store)
        var group = store.machineGroup
        UURemoteFolderSync.apply(devices: devices, folder: folder.name, ownDeviceID: credentials.deviceID, to: &group)
        if group != store.machineGroup { store.machineGroup = group }
    }

    /// The account's folder the first time: the "UU Remote" folder earlier
    /// versions put devices in (by name only, here or synced from another
    /// device) becomes it, so its servers are not left beside an empty one.
    private func adoptOrCreateFolder(store: CatusshStore) -> RDFolder {
        let source = RDFolder.Source.uuRemote(userID: userID)
        let legacy = "UU Remote"
        if let existing = store.folder(named: legacy), !existing.isLinked {
            var folders = store.folderGroup
            folders.folders.removeAll { $0.name == legacy }
            let adopted = RDFolder(id: existing.id, name: legacy, source: source)
            folders.folders.append(adopted)
            store.folderGroup = folders
            return adopted
        }
        return store.createFolder(named: legacy, source: source)
    }

    /// Desktop devices only, for the machine-binding picker.
    public var desktopDevices: [UUDeviceInfo] {
        devices.filter { $0.isDesktop && $0.deviceID != credentials.deviceID }
    }

    /// A server for a device, in the account's folder.
    public func makeMachine(for device: UUDeviceInfo, store: CatusshStore = .shared) -> RDMachine {
        UURemoteFolderSync.makeMachine(for: device, folder: folder(store: store)?.name ?? "UU Remote")
    }

    /// The saved server bound to a device, if one is.
    public func savedMachine(for device: UUDeviceInfo, store: CatusshStore = .shared) -> RDMachine? {
        store.machineGroup.machines.first { $0.uuDeviceID == device.deviceID }
    }

    /// The saved server bound to a device, adding one when there is none.
    public func upsertMachine(for device: UUDeviceInfo, store: CatusshStore = .shared) -> RDMachine {
        if let existing = savedMachine(for: device, store: store) { return existing }
        let machine = makeMachine(for: device, store: store)
        store.machineGroup.insert(machine)
        return machine
    }

    /// Registers the local machine as a UU device (for device-init flow).
    public func registerLocalDevice(name: String) async throws -> String {
        let clientID = credentials.clientID.isEmpty ? UUID().uuidString : credentials.clientID
        let systemID = credentials.systemID.isEmpty ? UUID().uuidString : credentials.systemID
        let deviceID = try await client.deviceWindowsInit(
            name: name,
            clientID: clientID,
            systemID: systemID,
            machineGUID: UUID().uuidString,
            os: "macOS",
            baseBoard: "Apple",
            cpu: "Apple Silicon",
            video: ["Apple GPU"],
            mac: "00-00-00-00-00-00",
            memory: 16 * 1024,
            screen: "1920x1080"
        )
        var creds = credentials
        creds.clientID = clientID
        creds.systemID = systemID
        creds.deviceID = deviceID
        credentials = creds
        persist()
        await client.updateCredentials(creds)
        return deviceID
    }

    // MARK: - QR rendering

    /// Renders QR content into PNG data via CoreImage.
    public static func makeQRCode(content: String, scale: Int = 8) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(content.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if canImport(UIKit)
            return UIImage(cgImage: cgImage).pngData()
        #else
            let rep = NSBitmapImageRep(cgImage: cgImage)
            return rep.representation(using: .png, properties: [:])
        #endif
    }

    /// Exposes the API client for the driver.
    public nonisolated var apiClient: UURemoteAPIClient { client }
}
