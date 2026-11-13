//
//  UURemoteAPIClientTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import XCTest

final class UURemoteAPIClientTests: XCTestCase {
    /// URLSession fails a GET that has a body, which is how the device list
    /// never loaded.
    func testGetRequestsHaveNoBody() {
        XCTAssertTrue(UUAPIRequest(method: "GET", path: "/api/v1/device/groups/of/my").body.isEmpty)
        XCTAssertEqual(UUAPIRequest(method: "POST", path: "/x").body, Data("{}".utf8))
    }

    /// Devices as the service lists them: flags are JSON booleans.
    func testDeviceFlagsReadAsBooleansOrNumbers() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"device_id":"d1","alias":"Macbook_Pro_M2","status":"CONNECTED","platform":4,"controllable":true,"support_wol":false}
        """.utf8)) as? [String: Any])
        let device = try XCTUnwrap(UURemoteAPIClient.device(from: json))
        XCTAssertTrue(device.controllable)
        XCTAssertFalse(device.supportWOL)
        XCTAssertTrue(device.isOnline && device.isDesktop)
        var numeric = json
        numeric["controllable"] = 1
        XCTAssertTrue(try XCTUnwrap(UURemoteAPIClient.device(from: numeric)).controllable)
    }

    /// The service refuses "+86" (code 1001, country_code must match
    /// `^(1\-(\d{3})|44\-\d{4}|\d{1,3})$`), which is how SMS sign-in never
    /// sent a code.
    func testPhoneNumbersGoOutAsTheServiceTakesThem() {
        XCTAssertEqual(UURemoteAPIClient.countryCode("+86"), "86")
        XCTAssertEqual(UURemoteAPIClient.countryCode(" +1-264 "), "1-264")
        XCTAssertEqual(UURemoteAPIClient.mobile("138 0013-8000"), "13800138000")
    }

    // MARK: - Borrowed sign-in

    private func device(_ id: String, platform: Int) -> UUDeviceInfo {
        var device = UUDeviceInfo()
        device.deviceID = id
        device.platform = platform
        return device
    }

    func testASignInUsingAMacHostsDeviceIsBorrowed() {
        let devices = [device("host-mac", platform: 4), device("catussh-own", platform: 1)]
        XCTAssertEqual(UURemoteAccountStore.borrowedHost(deviceID: "host-mac", in: devices)?.deviceID, "host-mac")
    }

    func testCatusshsOwnDeviceIsNotBorrowed() {
        let devices = [device("host-mac", platform: 4), device("catussh-own", platform: 1)]
        XCTAssertNil(UURemoteAccountStore.borrowedHost(deviceID: "catussh-own", in: devices))
    }

    func testADeviceNotOnTheAccountOrNoDeviceIsNotBorrowed() {
        let devices = [device("host-mac", platform: 4)]
        XCTAssertNil(UURemoteAccountStore.borrowedHost(deviceID: "elsewhere", in: devices))
        XCTAssertNil(UURemoteAccountStore.borrowedHost(deviceID: "", in: devices))
    }
}
