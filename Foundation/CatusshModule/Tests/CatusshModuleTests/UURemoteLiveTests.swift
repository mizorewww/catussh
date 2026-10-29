//
//  UURemoteLiveTests.swift
//  CatusshModuleTests
//
//  Calls the real UU Remote service; skipped unless UU_LIVE=1. Only
//  requests with no effect on the account (QR generation) run here.
//

@testable import CatusshModule
import ImageIO
import XCTest

final class UURemoteLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UU_LIVE"] == "1", "set UU_LIVE=1 to call the UU Remote service")
    }

    /// One signed POST, printing the status and body (tokens cut short).
    private func raw(_ path: String, body: Data = Data(), credentials: UUCredentials = UUCredentials()) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: UUConstants.apiBase + path)!)
        request.httpMethod = "POST"
        request.httpBody = body.isEmpty ? nil : body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in UURequestSigner.signedHeaders(credentials: credentials, method: "POST", pathWithQuery: path, body: body) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        print("UU_LIVE \(path) http \(status) \(text.prefix(300))")
        return (status, text)
    }

    func testRawQRCodeGeneration() async throws {
        _ = try await raw("/api/v1/qrcode/gen/login")
    }

    func testRawDeviceInitThenQRCode() async throws {
        var credentials = UUCredentials()
        credentials.clientID = UUID().uuidString.lowercased()
        credentials.systemID = UUID().uuidString
        let body = try JSONSerialization.data(withJSONObject: [
            "name": "catussh-probe", "client_id": credentials.clientID, "system_id": credentials.systemID,
            "machine_guid": UUID().uuidString.lowercased(), "os": "macOS", "base_board": "Apple", "cpu": "Apple M3 Max",
            "video": ["Apple GPU"], "mac": "02-00-00-00-00-01", "memory": 65536, "screen": "3456x2234",
        ])
        let (_, text) = try await raw("/api/v1/device/windows/init", body: body, credentials: credentials)
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        credentials.deviceID = (json?["data"] as? [String: Any])?["device_id"] as? String ?? ""
        XCTAssertFalse(credentials.deviceID.isEmpty)
        _ = try await raw("/api/v1/qrcode/gen/login", credentials: credentials)
    }

    /// The login flow as the account store runs it: register a device, then
    /// make a QR code and read its status once.
    func testQRCodeGeneration() async throws {
        var credentials = UUCredentials()
        credentials.clientID = UUID().uuidString
        credentials.systemID = UUID().uuidString
        let client = UURemoteAPIClient(credentials: credentials)
        credentials.deviceID = try await client.deviceWindowsInit(
            name: "catussh-probe", clientID: credentials.clientID, systemID: credentials.systemID,
            machineGUID: UUID().uuidString, os: "macOS", baseBoard: "Apple", cpu: "Apple Silicon",
            video: ["Apple GPU"], mac: "00-00-00-00-00-00", memory: 16 * 1024, screen: "1920x1080"
        )
        await client.updateCredentials(credentials)
        let result = try await client.qrcodeGenLogin()
        print("UU_LIVE qr ok url=\(result.qrcodeJumpURL.prefix(48))… ticket=\(result.statusQueryTicket.count) chars")
        let start = Date()
        let status = try await client.qrcodeLoginStatus(token: result.token, qrcodeJumpURL: result.qrcodeJumpURL, loginStatus: 1)
        print("UU_LIVE qr status=\(status) after \(Int(Date().timeIntervalSince(start)))s")
    }

    /// Without a registered device the service names the missing headers.
    func testQRCodeWithoutDeviceExplainsWhy() async throws {
        do {
            _ = try await UURemoteAPIClient().qrcodeGenLogin()
            XCTFail("expected a refusal")
        } catch let error as UUAPIError {
            print("UU_LIVE refusal: \(error.localizedDescription)")
            XCTAssertTrue(error.localizedDescription.contains("device-id"))
        }
    }

    // MARK: Signed in (a person scans the code)

    /// Where a signed-in session is kept between live runs; never in the repo.
    private var credentialsFile: URL? {
        ProcessInfo.processInfo.environment["UU_LIVE_CREDENTIALS"].map(URL.init(fileURLWithPath:))
    }

    /// Writes the QR code to UU_LIVE_QR (a PNG), waits up to three minutes
    /// for it to be scanned and confirmed, and saves the session.
    func testInteractiveQRLogin() async throws {
        let environment = ProcessInfo.processInfo.environment
        let qrPath = try XCTUnwrap(environment["UU_LIVE_QR"], "set UU_LIVE_QR to a PNG path")
        let output = try XCTUnwrap(credentialsFile, "set UU_LIVE_CREDENTIALS")
        var credentials = UUCredentials()
        credentials.clientID = UUID().uuidString
        credentials.systemID = UUID().uuidString
        let client = UURemoteAPIClient(credentials: credentials)
        credentials.deviceID = try await client.deviceWindowsInit(
            name: "catussh", clientID: credentials.clientID, systemID: credentials.systemID,
            machineGUID: UUID().uuidString, os: "macOS", baseBoard: "Apple", cpu: "Apple Silicon",
            video: ["Apple GPU"], mac: "00-00-00-00-00-00", memory: 16 * 1024, screen: "1920x1080"
        )
        await client.updateCredentials(credentials)
        let qr = try await client.qrcodeGenLogin()
        let png = await MainActor.run { UURemoteAccountStore.makeQRCode(content: qr.qrcodeJumpURL) }
        try XCTUnwrap(png).write(to: URL(fileURLWithPath: qrPath))
        print("UU_LIVE scan \(qrPath)")
        var last = 1
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            let status = try await client.qrcodeLoginStatus(token: qr.token, qrcodeJumpURL: qr.qrcodeJumpURL, loginStatus: last)
            print("UU_LIVE status \(status)")
            if status == 0 { XCTFail("the code expired"); return }
            if status == 4 {
                let login = try await client.loginByQRCode(token: qr.token, qrcodeJumpURL: qr.qrcodeJumpURL)
                credentials.userID = login.userID
                credentials.token = login.token
                credentials.csrf = UURequestSigner.csrf(from: login.token) ?? ""
                try JSONEncoder().encode(credentials).write(to: output, options: .completeFileProtection)
                print("UU_LIVE signed in as \(login.nickname) complete=\(credentials.isComplete)")
                return
            }
            last = status
        }
        XCTFail("nobody confirmed the code in time")
    }

    /// The account's devices, from a session saved by the login test.
    func testDeviceListSignedIn() async throws {
        let file = try XCTUnwrap(credentialsFile, "set UU_LIVE_CREDENTIALS")
        let credentials = try JSONDecoder().decode(UUCredentials.self, from: Data(contentsOf: file))
        let client = UURemoteAPIClient(credentials: credentials)
        let devices = try await client.deviceGroupsOfMy()
        for device in devices {
            print("UU_LIVE device \(device.alias) platform=\(device.platform) status=\(device.status) controllable=\(device.controllable)")
        }
    }

    /// One signed request with the saved session, printing the answer with
    /// long strings cut down.
    private func signedProbe(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let file = try XCTUnwrap(credentialsFile, "set UU_LIVE_CREDENTIALS")
        let credentials = try JSONDecoder().decode(UUCredentials.self, from: Data(contentsOf: file))
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var request = URLRequest(url: URL(string: UUConstants.apiBase + path)!)
        request.httpMethod = method
        request.httpBody = data.isEmpty ? nil : data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in UURequestSigner.signedHeaders(credentials: credentials, method: method, pathWithQuery: path, body: data) where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (answer, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any] ?? [:]
        let shown = try JSONSerialization.data(withJSONObject: UURemoteAPIClient.redacted(json), options: [.sortedKeys, .prettyPrinted])
        print("UU_LIVE \(method) \(path) http \((response as? HTTPURLResponse)?.statusCode ?? 0)\n\(String(decoding: shown, as: UTF8.self))")
        return json
    }

    /// What joining an online desktop's room answers.
    func testRoomJoinSignedIn() async throws {
        let groups = try await signedProbe("GET", "/api/v1/device/groups/of/my")
        let desktops = ((groups["data"] as? [String: Any])?["desktop_devices"] as? [[String: Any]]) ?? []
        for device in desktops {
            guard let id = device["device_id"] as? String else { continue }
            print("UU_LIVE device \(device["alias"] ?? "") status=\(device["status"] ?? "") availability=\(device["publisher_availability_status"] ?? "")")
            if (device["publisher_availability_status"] as? String) == "online" || (device["status"] as? String) == "CONNECTED" {
                _ = try await signedProbe("POST", "/api/v1/room/join/by_device/\(id)", body: ["force_join": true])
            }
        }
    }

    /// The desktop driver end to end against UU_LIVE_DEVICE (an alias):
    /// prints every phase and hint for 40 seconds.
    @MainActor
    func testDesktopSessionSignedIn() async throws {
        let file = try XCTUnwrap(credentialsFile, "set UU_LIVE_CREDENTIALS")
        let alias = try XCTUnwrap(ProcessInfo.processInfo.environment["UU_LIVE_DEVICE"], "set UU_LIVE_DEVICE")
        let credentials = try JSONDecoder().decode(UUCredentials.self, from: Data(contentsOf: file))
        let devices = try await UURemoteAPIClient(credentials: credentials).deviceGroupsOfMy()
        let device = try XCTUnwrap(devices.first { $0.alias == alias }, "no device \(alias)")
        await UURemoteAccountStore.shared.useForTesting(credentials, devices: devices)
        let session = RemoteDesktopSession(machine: UURemoteFolderSync.makeMachine(for: device, folder: "UU"), protocolType: .uuRemote)
        var seen: [String] = []
        let watch = session.$statusHint.combineLatest(session.$phase).sink { hint, phase in
            let line = "\(phase) · \(hint)"
            if seen.last != line { seen.append(line); print("UU_LIVE \(line)") }
        }
        session.connect()
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let image = session.frameImage {
                print("UU_LIVE first frame \(session.framebufferSize)")
                if let path = ProcessInfo.processInfo.environment["UU_LIVE_FRAME"],
                   let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
                {
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
                break
            }
            if case .failed = session.phase { break }
        }
        session.disconnect()
        watch.cancel()
    }
}
