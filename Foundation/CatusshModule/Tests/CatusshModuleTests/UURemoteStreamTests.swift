//
//  UURemoteStreamTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import XCTest

final class UURemoteStreamTests: XCTestCase {
    /// An empty output frame used to crash on the range 1...0.
    func testEmptyTerminalFramesDecodeToNothing() {
        let decoder = UTF8StreamDecoder()
        XCTAssertEqual(decoder.decode(Data()), "")
        XCTAssertEqual(decoder.decode(Data("ok".utf8)), "ok")
    }

    /// A character split across frames comes out whole, once.
    func testSplitCharactersWaitForTheirLastByte() {
        let decoder = UTF8StreamDecoder()
        let bytes = Array("终端".utf8)
        XCTAssertEqual(decoder.decode(Data(bytes[0 ..< 4])), "终")
        XCTAssertEqual(decoder.decode(Data(bytes[4...])), "端")
    }

    func testCodecComesFromParameterSets() {
        let hevc = [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x44, 0x01])]
        XCTAssertEqual(UUVideoAccessUnit.codec(ofParameterSetsIn: hevc), "H265")
        XCTAssertEqual(UUVideoAccessUnit.codec(ofParameterSetsIn: [Data([0x67, 0x64]), Data([0x68])]), "H264")
        XCTAssertNil(UUVideoAccessUnit.codec(ofParameterSetsIn: [Data([0x02, 0x01])]))
    }

    func testAnnexBSplitsOnBothStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x40, 0x01, 0, 0, 1, 0x42, 0x01, 0xAA])
        XCTAssertEqual(UUVideoAccessUnit.nalUnits(annexB: stream), [Data([0x40, 0x01]), Data([0x42, 0x01, 0xAA])])
    }

    /// Only what an answer says happened reaches the log.
    func testLoggedAnswersKeepNoTokensNamesOrNumbers() throws {
        let answer: [String: Any] = ["code": 0, "msg": "ok", "data": ["token": "abc", "alias": "My Mac", "mobile": "15800000059", "status": "CONNECTED"]]
        let shown = try XCTUnwrap(UURemoteAPIClient.redacted(answer) as? [String: Any])
        let data = try XCTUnwrap(shown["data"] as? [String: Any])
        XCTAssertEqual(shown["msg"] as? String, "ok")
        XCTAssertEqual(data["status"] as? String, "CONNECTED")
        XCTAssertEqual(data["token"] as? String, "…(3)")
        XCTAssertEqual(data["alias"] as? String, "…(6)")
        XCTAssertEqual(data["mobile"] as? String, "…(11)")
    }
}
