//
//  RemoteDesktopDriver.swift
//  CatusshModule
//
//  The protocol every remote-desktop backend (VNC, UU Remote, ...) speaks
//  to a session, plus the factory that picks a backend from a machine's
//  configuration. Drivers own their own networking and threads; everything
//  they report goes back through the session's nonisolated intake, which
//  lands it on the main actor.
//

import Foundation

/// A protocol backend driving one remote-desktop session.
public protocol RemoteDesktopDriver: AnyObject, Sendable {
    /// Starts connecting. Called once on the main actor; the driver may do
    /// all further work on its own threads.
    func start(session: RemoteDesktopSession)
    /// Stops the session permanently. After `stop`, no more callbacks
    /// should reach the session.
    func stop()

    /// Moves the pointer; button state rides along on the driver's own
    /// tracking (fed by `sendPointerButton`).
    func sendPointerMove(normalizedX: Double, normalizedY: Double)
    /// A button went down or up at the given normalized position.
    func sendPointerButton(_ button: MouseButton, isDown: Bool, normalizedX: Double, normalizedY: Double)
    /// Scroll deltas in wheel ticks (positive y = scroll up).
    func sendScroll(deltaX: Double, deltaY: Double, normalizedX: Double, normalizedY: Double)
    /// A physical key went down or up. `keySym` is the driver's preferred
    /// symbolic name when known; `characters` carries the text a key
    /// produces so drivers can fall back to text input.
    func sendKey(keyCode: UInt16, keySym: UInt32?, characters: String, isDown: Bool)
    /// Sends text as if typed (IME-friendly path when the driver has one).
    func sendText(_ text: String)
    /// Pushes the local pasteboard to the remote clipboard.
    func sendClipboard(_ text: String)

    /// Switches the display being viewed (multi-monitor hosts).
    func selectDisplay(_ displayID: Int)
    /// Applies a quality preference; the units are the driver's.
    func updateQuality(fps: Int, quality: Int)
    /// Asks the host for a full refresh / keyframe.
    func requestKeyframeOrRefresh()
}

/// Picks the backend for a machine. `.vnc` and `.uuRemote` are built in.
public enum RemoteDesktopDriverFactory {
    /// Creates a driver for the machine's protocol; nil for `.none`.
    @MainActor
    static func make(for machine: RDMachine, session: RemoteDesktopSession) -> RemoteDesktopDriver? {
        switch machine.remoteDesktopProtocol {
        case .none:
            return nil
        case .vnc:
            return VNCRFBDriver(machine: machine, session: session)
        case .uuRemote:
            return UURemoteDriver(session: session)
        }
    }
}
