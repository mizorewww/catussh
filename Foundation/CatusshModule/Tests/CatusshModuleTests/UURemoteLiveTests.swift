//
//  UURemoteLiveTests.swift
//  CatusshModuleTests
//
//  Calls the real UU Remote service; skipped unless UU_LIVE=1. Only
//  requests with no effect on the account (QR generation) run here.
//

@testable import CatusshModule
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
        let deadline = Date().addingTimeInterval(180)
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
}
