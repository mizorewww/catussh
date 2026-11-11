//
//  RemoteDesktopTouchInput.swift
//  CatusshModule
//
//  How fingers on a touch screen drive a remote desktop, after Moonlight's
//  iOS scheme. By default the screen is a trackpad: one finger moves the
//  pointer by how far it moves, a tap clicks, two fingers tap for a right
//  click and drag to scroll, tap and hold then drag holds the button,
//  pinching zooms the picture, three fingers tap for the keyboard. Direct
//  touch puts the pointer under the finger instead.
//
//  Nothing here knows UIKit: the canvas feeds it touches and turns what
//  comes out into pointer, wheel and view calls.
//

import CoreGraphics
import Foundation

/// How a finger drives the remote pointer. A pencil, a mouse and a
/// trackpad always point where they are.
public enum RemoteDesktopTouchMode: String, CaseIterable, Sendable {
    /// The screen is a trackpad: the pointer moves as far as the finger,
    /// faster the faster it goes.
    case trackpad
    /// The pointer goes where the finger touches.
    case direct

    /// Where the choice is kept: one for every desktop on this device, as
    /// it is about the hand, not the server.
    public static let defaultsKey = "me.mizorewww.rayon.remoteDesktop.touchMode"

    public var title: String {
        switch self {
        case .trackpad: "Trackpad"
        case .direct: "Direct Touch"
        }
    }

    public var systemImage: String {
        switch self {
        case .trackpad: "hand.point.up.left"
        case .direct: "hand.tap"
        }
    }
}

/// What a touch gesture asks of the desktop or the view.
public enum RemoteDesktopTouchAction: Equatable, Sendable {
    /// Trackpad: move the pointer by this much, in view points, already
    /// accelerated.
    case movePointer(by: CGVector)
    /// Direct touch: put the pointer under this view point.
    case placePointer(at: CGPoint)
    /// Press or let go of a button where the pointer is.
    case button(MouseButton, isDown: Bool)
    /// Press and let go of a button where the pointer is.
    case click(MouseButton)
    /// Two fingers moved by this much, in view points; positive y is down
    /// the screen (content pulled down, so scrolling up).
    case scroll(by: CGVector)
    /// A pinch: the view scales by `scale` about `anchor` and moves by
    /// `pan`, both in view points.
    case zoom(scale: CGFloat, anchor: CGPoint, pan: CGVector)
    /// Three fingers tapped: the software keyboard comes or goes.
    case toggleKeyboard
}

/// Turns finger touches into `RemoteDesktopTouchAction`s. Feed it every
/// direct touch as it begins, moves and ends, keyed by an id that stays the
/// same for a finger; times are in seconds on one clock.
public struct RemoteDesktopTouchGestures {
    public var mode: RemoteDesktopTouchMode

    /// How far a finger may wander and still tap, in points.
    public static let slop: CGFloat = 10
    /// A finger held this long before it moves drags; held this long and
    /// let go without moving, it right-clicks.
    public static let holdDuration: TimeInterval = 0.45
    /// Two or three fingers down and up within this tap.
    public static let multiTapDuration: TimeInterval = 0.5
    /// How much two fingers must spread or close before they zoom rather
    /// than scroll.
    public static let pinchThreshold: CGFloat = 0.12

    private enum State: Equatable {
        case idle
        /// One finger down, not moved past the slop yet.
        case touching(finger: Int)
        /// Trackpad: one finger moving the pointer.
        case moving(finger: Int)
        /// One finger holding the left button.
        case dragging(finger: Int)
        /// Two fingers, not yet scrolling or zooming.
        case twoFingers
        case scrolling
        case zooming
        /// What was going on is over; nothing more until every finger is up.
        case finished
    }

    private var state: State = .idle
    private var touches: [Int: CGPoint] = [:]
    private var starts: [Int: CGPoint] = [:]
    private var beganAt: TimeInterval = 0
    private var lastMoveAt: TimeInterval = 0
    private var mostFingers = 0
    /// Some finger went past the slop: not a tap.
    private var wandered = false
    private var lastCentroid = CGPoint.zero
    private var startSpread: CGFloat = 0
    private var lastSpread: CGFloat = 0

    public init(mode: RemoteDesktopTouchMode = .trackpad) {
        self.mode = mode
    }

    /// Fingers touched down.
    public mutating func began(_ new: [Int: CGPoint], at time: TimeInterval) -> [RemoteDesktopTouchAction] {
        guard !new.isEmpty else { return [] }
        if touches.isEmpty {
            state = .idle
            beganAt = time
            lastMoveAt = time
            mostFingers = 0
            wandered = false
            starts = [:]
        }
        for (id, point) in new {
            touches[id] = point
            starts[id] = point
        }
        mostFingers = max(mostFingers, touches.count)
        switch state {
        case .dragging:
            // A finger joining a drag changes nothing.
            return []
        case .idle where touches.count == 1:
            let (finger, point) = touches.first!
            state = .touching(finger: finger)
            return mode == .direct ? [.placePointer(at: point)] : []
        case .idle, .touching, .moving, .twoFingers:
            if touches.count == 2 {
                state = .twoFingers
                lastCentroid = centroid
                startSpread = spread
                lastSpread = startSpread
            } else {
                state = .finished
            }
            return []
        case .scrolling, .zooming, .finished:
            state = .finished
            return []
        }
    }

    /// Fingers moved to these points.
    public mutating func moved(_ points: [Int: CGPoint], at time: TimeInterval) -> [RemoteDesktopTouchAction] {
        var previous: [Int: CGPoint] = [:]
        for (id, point) in points where touches[id] != nil {
            previous[id] = touches[id]
            touches[id] = point
            if let start = starts[id], distance(start, point) > Self.slop { wandered = true }
        }
        guard !previous.isEmpty else { return [] }
        let interval = time - lastMoveAt
        lastMoveAt = time
        switch state {
        case let .touching(finger):
            guard let point = touches[finger], let start = starts[finger], distance(start, point) > Self.slop else { return [] }
            let travelled = CGVector(dx: point.x - start.x, dy: point.y - start.y)
            // Held still first, or a finger on the picture itself: the
            // button goes down where the pointer is, and the drag follows.
            if mode == .direct || time - beganAt >= Self.holdDuration {
                state = .dragging(finger: finger)
                return [.button(.left, isDown: true), follow(travelled, to: point, interval: interval)]
            }
            state = .moving(finger: finger)
            return [follow(travelled, to: point, interval: interval)]
        case let .moving(finger), let .dragging(finger):
            guard let point = touches[finger], let last = previous[finger] else { return [] }
            return [follow(CGVector(dx: point.x - last.x, dy: point.y - last.y), to: point, interval: interval)]
        case .twoFingers:
            let now = centroid
            if startSpread > 0, abs(spread / startSpread - 1) > Self.pinchThreshold {
                state = .zooming
                return [pinch(to: now)]
            }
            guard distance(lastCentroid, now) > Self.slop else { return [] }
            state = .scrolling
            return [scroll(to: now)]
        case .scrolling:
            return [scroll(to: centroid)]
        case .zooming:
            return [pinch(to: centroid)]
        case .idle, .finished:
            return []
        }
    }

    /// Fingers lifted.
    public mutating func ended(_ ids: [Int], at time: TimeInterval) -> [RemoteDesktopTouchAction] {
        let lifted = ids.filter { touches[$0] != nil }
        guard !lifted.isEmpty else { return [] }
        for id in lifted { touches[id] = nil }
        if touches.isEmpty {
            defer { state = .idle }
            if case .dragging = state { return [.button(.left, isDown: false)] }
            guard !wandered else { return [] }
            let held = time - beganAt
            switch mostFingers {
            case 1:
                // A finger held still and let go is a long press: the
                // context menu, as it is on iPad.
                return [.click(held >= Self.holdDuration ? .right : .left)]
            case 2 where held < Self.multiTapDuration:
                return [.click(.right)]
            case 3 where held < Self.multiTapDuration:
                return [.toggleKeyboard]
            default:
                return []
            }
        }
        switch state {
        case let .dragging(finger) where lifted.contains(finger):
            state = .finished
            return [.button(.left, isDown: false)]
        case .twoFingers, .scrolling, .zooming:
            // One of two fingers left: the gesture is over (a two-finger
            // tap rarely lifts both at once, so it still counts as one).
            state = .finished
            return []
        case let .moving(finger) where lifted.contains(finger):
            state = .finished
            return []
        default:
            return []
        }
    }

    /// The system took the touches (a gesture of its own, a call): a held
    /// button is let go.
    public mutating func cancelled() -> [RemoteDesktopTouchAction] {
        defer {
            state = .idle
            touches = [:]
            starts = [:]
        }
        if case .dragging = state { return [.button(.left, isDown: false)] }
        return []
    }

    // MARK: - Helpers

    private func follow(_ delta: CGVector, to point: CGPoint, interval: TimeInterval) -> RemoteDesktopTouchAction {
        switch mode {
        case .trackpad: .movePointer(by: RemoteDesktopPointerAcceleration.accelerate(delta, over: interval))
        case .direct: .placePointer(at: point)
        }
    }

    private mutating func scroll(to now: CGPoint) -> RemoteDesktopTouchAction {
        defer { lastCentroid = now }
        return .scroll(by: CGVector(dx: now.x - lastCentroid.x, dy: now.y - lastCentroid.y))
    }

    private mutating func pinch(to now: CGPoint) -> RemoteDesktopTouchAction {
        let current = spread
        defer {
            lastCentroid = now
            lastSpread = current
        }
        let scale = lastSpread > 0 ? current / lastSpread : 1
        return .zoom(scale: scale, anchor: now, pan: CGVector(dx: now.x - lastCentroid.x, dy: now.y - lastCentroid.y))
    }

    /// The first two fingers, by id, so the pair is stable.
    private var pair: [CGPoint] {
        touches.keys.sorted().prefix(2).compactMap { touches[$0] }
    }

    private var centroid: CGPoint {
        let points = pair
        guard !points.isEmpty else { return .zero }
        return CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
            y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
        )
    }

    private var spread: CGFloat {
        let points = pair
        guard points.count == 2 else { return 0 }
        return distance(points[0], points[1])
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Trackpad pointer acceleration: slow strokes move the pointer less than
/// the finger, for precision; quick ones carry it across the screen.
public enum RemoteDesktopPointerAcceleration {
    /// The gain at a crawl and the most it reaches.
    public static let minimumGain: CGFloat = 0.75
    public static let maximumGain: CGFloat = 3
    /// Points per second that add one to the gain.
    public static let speedPerGain: CGFloat = 700

    /// The gain for a finger moving this fast, in points per second.
    public static func gain(speed: CGFloat) -> CGFloat {
        min(maximumGain, max(minimumGain, minimumGain + max(speed, 0) / speedPerGain))
    }

    /// `delta`, moved over `interval` seconds, scaled by its speed's gain.
    public static func accelerate(_ delta: CGVector, over interval: TimeInterval) -> CGVector {
        // Touches come at 120 Hz at most; a zero interval is one frame.
        let seconds = CGFloat(max(interval, 1.0 / 120))
        let factor = gain(speed: hypot(delta.dx, delta.dy) / seconds)
        return CGVector(dx: delta.dx * factor, dy: delta.dy * factor)
    }
}

/// The local zoom of the remote picture: how far it is magnified and which
/// part of it is in the middle of the view. At 1 the picture fits the view.
public struct RemoteDesktopViewport: Equatable, Sendable {
    public static let maximumZoom: CGFloat = 5

    public private(set) var zoom: CGFloat = 1
    /// The point of the picture, normalized, at the middle of the view.
    public private(set) var center = CGPoint(x: 0.5, y: 0.5)

    public init() {}

    /// Where the picture is drawn, in view coordinates: `base` (the picture
    /// fitted to `bounds`) magnified, and kept over the view.
    public func rect(fitting base: CGRect, in bounds: CGRect) -> CGRect {
        guard zoom > 1, base.width > 0, base.height > 0 else { return base }
        let size = CGSize(width: base.width * zoom, height: base.height * zoom)
        let x = clampedOrigin(bounds.midX - center.x * size.width, size.width, bounds.minX, bounds.width)
        let y = clampedOrigin(bounds.midY - center.y * size.height, size.height, bounds.minY, bounds.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Scales by `scale` about `anchor` and moves by `pan` (view points).
    public mutating func zoom(by scale: CGFloat, anchor: CGPoint, pan: CGVector, base: CGRect, bounds: CGRect) {
        guard scale > 0, base.width > 0, base.height > 0 else { return }
        let current = rect(fitting: base, in: bounds)
        let nx = (anchor.x - current.minX) / current.width
        let ny = (anchor.y - current.minY) / current.height
        let newZoom = min(Self.maximumZoom, max(1, zoom * scale))
        guard newZoom > 1 else {
            reset()
            return
        }
        let size = CGSize(width: base.width * newZoom, height: base.height * newZoom)
        let origin = CGPoint(x: anchor.x + pan.dx - nx * size.width, y: anchor.y + pan.dy - ny * size.height)
        zoom = newZoom
        settle(origin: origin, size: size, bounds: bounds)
    }

    /// Moves the picture by `delta` view points.
    public mutating func pan(by delta: CGVector, base: CGRect, bounds: CGRect) {
        guard zoom > 1 else { return }
        let current = rect(fitting: base, in: bounds)
        settle(
            origin: CGPoint(x: current.minX + delta.dx, y: current.minY + delta.dy),
            size: current.size,
            bounds: bounds
        )
    }

    /// Pans just enough that the normalized `point` is at least `margin`
    /// points inside the view: a trackpad pointer never leaves the screen.
    public mutating func reveal(_ point: CGPoint, margin: CGFloat, base: CGRect, bounds: CGRect) {
        guard zoom > 1 else { return }
        let current = rect(fitting: base, in: bounds)
        let x = current.minX + point.x * current.width
        let y = current.minY + point.y * current.height
        let inset = bounds.insetBy(dx: min(margin, bounds.width / 2), dy: min(margin, bounds.height / 2))
        var delta = CGVector.zero
        if x < inset.minX { delta.dx = inset.minX - x } else if x > inset.maxX { delta.dx = inset.maxX - x }
        if y < inset.minY { delta.dy = inset.minY - y } else if y > inset.maxY { delta.dy = inset.maxY - y }
        guard delta != .zero else { return }
        pan(by: delta, base: base, bounds: bounds)
    }

    public mutating func reset() {
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
    }

    /// Keeps the picture over the view and records its middle.
    private mutating func settle(origin: CGPoint, size: CGSize, bounds: CGRect) {
        let x = clampedOrigin(origin.x, size.width, bounds.minX, bounds.width)
        let y = clampedOrigin(origin.y, size.height, bounds.minY, bounds.height)
        center = CGPoint(x: (bounds.midX - x) / size.width, y: (bounds.midY - y) / size.height)
    }

    /// A picture wider than the view covers it; a narrower one is centred.
    private func clampedOrigin(_ origin: CGFloat, _ length: CGFloat, _ viewMin: CGFloat, _ viewLength: CGFloat) -> CGFloat {
        guard length > viewLength else { return viewMin + (viewLength - length) / 2 }
        return min(viewMin, max(viewMin + viewLength - length, origin))
    }
}
