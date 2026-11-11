//
//  RemoteDesktopTouchInputTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import CoreGraphics
import XCTest

final class RemoteDesktopTouchInputTests: XCTestCase {
    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: - Trackpad

    func testTrackpadTapClicksWithoutMovingThePointer() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        XCTAssertEqual(gestures.began([1: p(100, 100)], at: 0), [])
        XCTAssertEqual(gestures.moved([1: p(103, 102)], at: 0.05), [])
        XCTAssertEqual(gestures.ended([1], at: 0.1), [.click(.left)])
    }

    func testTrackpadDragMovesThePointerRelatively() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        _ = gestures.began([1: p(100, 100)], at: 0)
        let first = gestures.moved([1: p(130, 100)], at: 0.05)
        guard case let .movePointer(by: delta)? = first.first, first.count == 1 else {
            return XCTFail("expected a relative move, got \(first)")
        }
        XCTAssertGreaterThan(delta.dx, 0)
        XCTAssertEqual(delta.dy, 0)
        let second = gestures.moved([1: p(130, 110)], at: 0.1)
        guard case let .movePointer(by: down)? = second.first else { return XCTFail("\(second)") }
        XCTAssertEqual(down.dx, 0)
        XCTAssertGreaterThan(down.dy, 0)
        XCTAssertEqual(gestures.ended([1], at: 0.2), [], "a moved finger does not click")
    }

    func testTrackpadHoldThenDragHoldsTheLeftButton() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        _ = gestures.began([1: p(100, 100)], at: 0)
        let actions = gestures.moved([1: p(140, 100)], at: 0.6)
        XCTAssertEqual(actions.first, .button(.left, isDown: true))
        XCTAssertEqual(actions.count, 2)
        guard case .movePointer(by:) = actions[1] else { return XCTFail("\(actions)") }
        guard case .movePointer(by:)? = gestures.moved([1: p(150, 100)], at: 0.65).first else { return XCTFail() }
        XCTAssertEqual(gestures.ended([1], at: 0.8), [.button(.left, isDown: false)])
    }

    func testHoldWithoutMovingRightClicks() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        _ = gestures.began([1: p(100, 100)], at: 0)
        XCTAssertEqual(gestures.ended([1], at: 0.7), [.click(.right)])
    }

    func testTwoFingerTapRightClicksEvenWhenFingersLiftApart() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        _ = gestures.began([1: p(100, 100)], at: 0)
        _ = gestures.began([2: p(160, 100)], at: 0.02)
        XCTAssertEqual(gestures.ended([1], at: 0.12), [])
        XCTAssertEqual(gestures.ended([2], at: 0.15), [.click(.right)])
    }

    func testTwoFingerDragScrolls() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        _ = gestures.began([1: p(100, 100), 2: p(160, 100)], at: 0)
        XCTAssertEqual(gestures.moved([1: p(100, 105), 2: p(160, 105)], at: 0.03), [], "within the slop")
        XCTAssertEqual(gestures.moved([1: p(100, 130), 2: p(160, 130)], at: 0.06), [.scroll(by: CGVector(dx: 0, dy: 30))])
        XCTAssertEqual(gestures.moved([1: p(100, 140), 2: p(160, 140)], at: 0.09), [.scroll(by: CGVector(dx: 0, dy: 10))])
        XCTAssertEqual(gestures.ended([1, 2], at: 0.2), [], "a scroll does not click")
    }

    func testPinchZoomsAndPans() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        _ = gestures.began([1: p(100, 100), 2: p(200, 100)], at: 0)
        let actions = gestures.moved([1: p(80, 110), 2: p(220, 110)], at: 0.05)
        guard case let .zoom(scale, anchor, pan)? = actions.first else { return XCTFail("\(actions)") }
        XCTAssertEqual(scale, 1.4, accuracy: 0.001)
        XCTAssertEqual(anchor, p(150, 110))
        XCTAssertEqual(pan, CGVector(dx: 0, dy: 10))
        // Once zooming, it keeps zooming, even if the spread holds.
        guard case .zoom? = gestures.moved([1: p(80, 130), 2: p(220, 130)], at: 0.1).first else { return XCTFail() }
    }

    func testThreeFingerTapTogglesTheKeyboard() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        _ = gestures.began([1: p(100, 100), 2: p(150, 100)], at: 0)
        _ = gestures.began([3: p(200, 100)], at: 0.03)
        XCTAssertEqual(gestures.ended([1, 2], at: 0.15), [])
        XCTAssertEqual(gestures.ended([3], at: 0.17), [.toggleKeyboard])
    }

    func testSlowThreeFingersDoNothing() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        _ = gestures.began([1: p(100, 100), 2: p(150, 100), 3: p(200, 100)], at: 0)
        XCTAssertEqual(gestures.ended([1, 2, 3], at: 1), [])
    }

    func testCancelLetsGoOfAHeldButton() {
        var gestures = RemoteDesktopTouchGestures(mode: .trackpad)
        _ = gestures.began([1: p(100, 100)], at: 0)
        _ = gestures.moved([1: p(140, 100)], at: 0.6)
        XCTAssertEqual(gestures.cancelled(), [.button(.left, isDown: false)])
        XCTAssertEqual(gestures.ended([1], at: 0.7), [], "the cancelled finger is forgotten")
    }

    // MARK: - Direct touch

    func testDirectTapPointsThenClicks() {
        var gestures = RemoteDesktopTouchGestures(mode: .direct)
        XCTAssertEqual(gestures.began([1: p(40, 60)], at: 0), [.placePointer(at: p(40, 60))])
        XCTAssertEqual(gestures.ended([1], at: 0.1), [.click(.left)])
    }

    func testDirectDragHoldsTheButtonUnderTheFinger() {
        var gestures = RemoteDesktopTouchGestures(mode: .direct)
        _ = gestures.began([1: p(40, 60)], at: 0)
        XCTAssertEqual(gestures.moved([1: p(80, 60)], at: 0.05), [.button(.left, isDown: true), .placePointer(at: p(80, 60))])
        XCTAssertEqual(gestures.moved([1: p(90, 70)], at: 0.1), [.placePointer(at: p(90, 70))])
        XCTAssertEqual(gestures.ended([1], at: 0.2), [.button(.left, isDown: false)])
    }

    func testDirectLongPressRightClicks() {
        var gestures = RemoteDesktopTouchGestures(mode: .direct)
        _ = gestures.began([1: p(40, 60)], at: 0)
        XCTAssertEqual(gestures.ended([1], at: 0.8), [.click(.right)])
    }

    // MARK: - Acceleration

    func testAccelerationGrowsWithSpeedAndIsBounded() {
        let slow = RemoteDesktopPointerAcceleration.gain(speed: 50)
        let quick = RemoteDesktopPointerAcceleration.gain(speed: 800)
        XCTAssertLessThan(slow, 1, "a crawl is finer than the finger")
        XCTAssertGreaterThan(quick, slow)
        XCTAssertEqual(RemoteDesktopPointerAcceleration.gain(speed: 100_000), RemoteDesktopPointerAcceleration.maximumGain)
        XCTAssertEqual(RemoteDesktopPointerAcceleration.gain(speed: -1), RemoteDesktopPointerAcceleration.minimumGain)
        XCTAssertEqual(RemoteDesktopPointerAcceleration.accelerate(.zero, over: 0), .zero)
        let moved = RemoteDesktopPointerAcceleration.accelerate(CGVector(dx: 3, dy: 4), over: 0.01)
        XCTAssertEqual(moved.dx / moved.dy, 0.75, accuracy: 0.0001, "the direction is kept")
    }

    // MARK: - Viewport

    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let base = CGRect(x: 0, y: 118.75, width: 1000, height: 562.5) // 16:9 fitted

    func testViewportFitsUntilZoomed() {
        let viewport = RemoteDesktopViewport()
        XCTAssertEqual(viewport.rect(fitting: base, in: bounds), base)
    }

    func testViewportZoomKeepsTheAnchorUnderTheFingers() {
        var viewport = RemoteDesktopViewport()
        let anchor = p(250, 400)
        let before = viewport.rect(fitting: base, in: bounds)
        let nx = (anchor.x - before.minX) / before.width
        viewport.zoom(by: 2, anchor: anchor, pan: .zero, base: base, bounds: bounds)
        let after = viewport.rect(fitting: base, in: bounds)
        XCTAssertEqual(viewport.zoom, 2)
        XCTAssertEqual(after.width, 2000)
        XCTAssertEqual(after.minX + nx * after.width, anchor.x, accuracy: 0.001)
        // Zooming back out past 1 fits again.
        viewport.zoom(by: 0.1, anchor: anchor, pan: .zero, base: base, bounds: bounds)
        XCTAssertEqual(viewport.zoom, 1)
        XCTAssertEqual(viewport.rect(fitting: base, in: bounds), base)
    }

    func testViewportStaysOverTheView() {
        var viewport = RemoteDesktopViewport()
        viewport.zoom(by: 3, anchor: p(500, 400), pan: .zero, base: base, bounds: bounds)
        viewport.pan(by: CGVector(dx: 10_000, dy: 10_000), base: base, bounds: bounds)
        let rect = viewport.rect(fitting: base, in: bounds)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(viewport.zoom, RemoteDesktopViewport.maximumZoom)
    }

    func testViewportRevealsAPointerOffScreen() {
        var viewport = RemoteDesktopViewport()
        viewport.zoom(by: 4, anchor: p(0, 400), pan: .zero, base: base, bounds: bounds)
        let far = p(0.95, 0.5)
        viewport.reveal(far, margin: 40, base: base, bounds: bounds)
        let rect = viewport.rect(fitting: base, in: bounds)
        let x = rect.minX + far.x * rect.width
        XCTAssertLessThanOrEqual(x, bounds.maxX - 40 + 0.001)
        XCTAssertGreaterThanOrEqual(x, bounds.minX)
    }
}
