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
}
