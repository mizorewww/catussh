//
//  RemoteDesktopTypes.swift
//  CatusshModule
//
//  Shared types for the remote-desktop feature, protocol-agnostic: a VNC
//  session and a UU Remote session both report the same shape.
//

import CoreGraphics
import Foundation

/// A failure a remote desktop session can explain to a person.
public struct RemoteDesktopFailure: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Where a remote desktop session is in its lifetime. Views match on this;
/// the strings it carries are hints for people, not state.
public enum RemoteDesktopPhase: Sendable, Equatable {
    /// Nothing started yet.
    case idle
    /// Reaching the host / transport is being set up.
    case connecting(String)
    /// The transport is up; credentials are being checked.
    case authenticating
    /// Frames and input flow.
    case connected
    /// The session ended cleanly, with an optional reason.
    case closed(String?)
    /// The session ended with a failure, with a reason for the person.
    case failed(String)
}

/// A physical mouse button, independent of how a protocol encodes it.
public enum MouseButton: String, Sendable, CaseIterable {
    case left, middle, right, back, forward
}

/// One display the remote host exposes.
public struct RemoteDisplayInfo: Identifiable, Equatable, Sendable {
    public var id: Int
    public var name: String
    public var width: Int
    public var height: Int
    /// The display's native refresh, when the host reports it.
    public var fps: Int
    public var isPrimary: Bool

    public init(id: Int, name: String = "", width: Int = 0, height: Int = 0, fps: Int = 60, isPrimary: Bool = false) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.fps = fps
        self.isPrimary = isPrimary
    }
}

/// The remote cursor as the host describes it (position is normalized to
/// the framebuffer: 0...1 on each axis).
public struct RemoteCursorInfo: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Int
    public var height: Int
    public var image: CGImage?
    public var visible: Bool

    public init(x: Double = 0, y: Double = 0, width: Int = 0, height: Int = 0, image: CGImage? = nil, visible: Bool = false) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.image = image
        self.visible = visible
    }

    public static func == (lhs: RemoteCursorInfo, rhs: RemoteCursorInfo) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.width == rhs.width
            && lhs.height == rhs.height && lhs.visible == rhs.visible
            && lhs.image === rhs.image
    }
}
