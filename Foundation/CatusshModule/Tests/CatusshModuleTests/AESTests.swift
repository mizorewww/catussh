//
//  AESTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import XCTest

final class AESTests: XCTestCase {
    private let key = "test-master-key-0123456789abcdef"

    private var engine: AES {
        AES(key: key)!
    }

    func testNewFormatRoundTrip() throws {
        let plain = Data("servers and identities".utf8)
        let encrypted = try XCTUnwrap(engine.encrypt(data: plain))
        XCTAssertTrue(encrypted.starts(with: Data("RGCM2".utf8)))
        XCTAssertEqual(engine.decrypt(data: encrypted), plain)
    }

    func testEncryptingTwiceProducesDifferentBytes() throws {
        let plain = Data("same input".utf8)
        let first = try XCTUnwrap(engine.encrypt(data: plain))
        let second = try XCTUnwrap(engine.encrypt(data: plain))
        XCTAssertNotEqual(first, second, "a random nonce per write")
    }

    func testNonASCIIAndShortKeysDeriveCleanlyViaHKDF() throws {
        let unicodeEngine = try XCTUnwrap(AES(key: "密钥密码🔐"))
        let plain = Data("unicode key test".utf8)
        let encrypted = try XCTUnwrap(unicodeEngine.encrypt(data: plain))
        XCTAssertEqual(unicodeEngine.decrypt(data: encrypted), plain)
        XCTAssertNil(engine.decrypt(data: encrypted))
    }

    func testRandomMasterKeyHas256BitEntropy() {
        let generated = AES.generateRandomMasterKey()
        let decoded = Data(base64Encoded: generated)
        XCTAssertEqual(decoded?.count, 32)
    }

    func testTamperedCiphertextIsRefused() throws {
        var encrypted = try XCTUnwrap(engine.encrypt(data: Data("payload".utf8)))
        encrypted[encrypted.count - 1] ^= 1
        XCTAssertNil(engine.decrypt(data: encrypted))
    }

    func testSharedEngineRoundTrips() throws {
        let plain = Data("through the shared engine".utf8)
        let encrypted = try XCTUnwrap(AES.shared.encrypt(data: plain))
        XCTAssertEqual(AES.shared.decrypt(data: encrypted), plain)
    }

    func testConstantKeyCiphertextReadsThroughFallback() throws {
        let plain = Data("written by an old debug build".utf8)
        let gcm = try XCTUnwrap(legacyDebugEngine.encrypt(data: plain))
        XCTAssertNil(engine.decrypt(data: gcm), "a different key alone must not open it")
        XCTAssertEqual(engine.withLegacyDebugKeyFallback().decrypt(data: gcm), plain)
    }

    func testWritesSkipTheFallbackKey() throws {
        let fresh = Data("fresh write".utf8)
        let encrypted = try XCTUnwrap(engine.withLegacyDebugKeyFallback().encrypt(data: fresh))
        XCTAssertEqual(engine.decrypt(data: encrypted), fresh)
        XCTAssertNil(
            legacyDebugEngine.decrypt(data: encrypted),
            "writes use the new key, moving the data over on the next save"
        )
    }

    private var legacyDebugEngine: AES {
        AES(key: AES.legacyDebugKey + AES.legacyDebugKey + AES.legacyDebugKey)!
    }
}
