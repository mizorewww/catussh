//
//  UURemoteInputTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import XCTest

final class UURemoteInputTests: XCTestCase {
    private let control = "CONTROL_DATA_CHANNEL"

    private func move(_ x: Double) -> UUChannelOutbox.Message {
        .init(label: control, data: UUControlProtocol.mouseMoveAbsolute(x: x, y: 0.5), kind: .pointerMove)
    }

    private func press() -> UUChannelOutbox.Message {
        .init(label: control, data: UUControlProtocol.mouseButton(.left, isDown: true), kind: .input)
    }

    private func heartbeat() -> UUChannelOutbox.Message {
        .init(label: control, data: UUControlProtocol.keyboardHeartbeat(), kind: .other)
    }

    func testWaitingPointerMovesCollapseToTheLatest() {
        var outbox = UUChannelOutbox()
        for step in 0 ..< 120 { outbox.push(move(Double(step) / 120)) }
        XCTAssertEqual(outbox.pending, [move(119.0 / 120)])
    }

    func testAHeartbeatBetweenMovesDoesNotKeepThemAll() {
        var outbox = UUChannelOutbox()
        outbox.push(move(0.1))
        outbox.push(heartbeat())
        outbox.push(move(0.2))
        XCTAssertEqual(outbox.pending, [move(0.2), heartbeat()])
    }

    func testAMoveBeforeAPressStays() {
        var outbox = UUChannelOutbox()
        outbox.push(move(0.1))
        outbox.push(press())
        outbox.push(move(0.2))
        outbox.push(move(0.3))
        XCTAssertEqual(outbox.pending, [move(0.1), press(), move(0.3)])
    }

    func testBatchesStayInOrderAndBounded() {
        var outbox = UUChannelOutbox()
        let chunk = Data(repeating: 7, count: UUChannelOutbox.batchBytes / 2 + 1)
        for _ in 0 ..< 3 { outbox.push(.init(label: "FILE_DATA_CHANNEL", data: chunk, kind: .other)) }
        outbox.push(press())
        XCTAssertEqual(outbox.take().count, 1)
        XCTAssertEqual(outbox.take().count, 1)
        let last = outbox.take()
        XCTAssertEqual(last.count, 2)
        XCTAssertEqual(last.last, press())
        XCTAssertTrue(outbox.take().isEmpty)
    }

    func testAnOversizedMessageStillGoes() {
        var outbox = UUChannelOutbox()
        outbox.push(.init(label: "FILE_DATA_CHANNEL", data: Data(count: UUChannelOutbox.batchBytes * 2), kind: .other))
        XCTAssertEqual(outbox.take().count, 1)
    }

    func testBatchScript() {
        let script = UUChannelOutbox.script(for: [press()])
        let b64 = UUControlProtocol.mouseButton(.left, isDown: true).base64EncodedString()
        XCTAssertEqual(script, #"dcSendBatch([["CONTROL_DATA_CHANNEL","\#(b64)"]])"#)
    }

    func testAbsoluteMovesAreAlwaysJSONNumbersOnTheScreen() throws {
        for (x, y) in [(Double.nan, 0.5), (.infinity, -.infinity), (-3, 7), (0.25, 0.75)] {
            let data = UUControlProtocol.mouseMoveAbsolute(x: x, y: y)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let ax = try XCTUnwrap(json["abs_x"] as? Double)
            let ay = try XCTUnwrap(json["abs_y"] as? Double)
            XCTAssertTrue((0 ... 1).contains(ax) && (0 ... 1).contains(ay), "\(x), \(y) -> \(ax), \(ay)")
        }
    }

    func testSessionPositionsAreClampedAndNumbers() {
        XCTAssertNil(RemoteDesktopSession.onScreen(.nan, 0.5))
        XCTAssertNil(RemoteDesktopSession.onScreen(0.5, .infinity))
        let clamped = RemoteDesktopSession.onScreen(-0.2, 1.4)
        XCTAssertEqual(clamped?.x, 0)
        XCTAssertEqual(clamped?.y, 1)
    }

    // MARK: - Cursor

    func testTheCursorIsDrawnAtThePointerLessItsHotspot() throws {
        let shape = RemoteCursorInfo(x: 4, y: 2, width: 32, height: 32, visible: true)
        let placed = try XCTUnwrap(UURemoteDriver.placedCursor(shape, at: (0.5, 0.25), on: CGSize(width: 1000, height: 500)))
        XCTAssertEqual(placed.x, 0.5 - 4.0 / 1000, accuracy: 1e-9)
        XCTAssertEqual(placed.y, 0.25 - 2.0 / 500, accuracy: 1e-9)
        XCTAssertEqual(placed.width, 32)
        XCTAssertTrue(placed.visible)
    }

    func testAHotspotOutsideTheShapePutsTheTipAtThePointer() throws {
        let shape = RemoteCursorInfo(x: 812, y: 460, width: 32, height: 32, visible: true)
        let placed = try XCTUnwrap(UURemoteDriver.placedCursor(shape, at: (0.3, 0.6), on: CGSize(width: 1920, height: 1080)))
        XCTAssertEqual(placed.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(placed.y, 0.6, accuracy: 1e-9)
    }

    func testNoCursorBeforeTheScreenSizeIsKnown() {
        let shape = RemoteCursorInfo(x: 0, y: 0, width: 32, height: 32, visible: true)
        XCTAssertNil(UURemoteDriver.placedCursor(shape, at: (0.5, 0.5), on: .zero))
    }
}
