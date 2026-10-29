//
//  RemoteDesktopSession.swift
//  CatusshModule
//
//  One open remote-desktop session (VNC or UU Remote): the published state a
//  stage view draws, and the input calls the view makes. The driver reports
//  through `report*` intake methods, which land every mutation here on the
//  main actor.
//

import Combine
import CoreGraphics
import Foundation

@MainActor
public final class RemoteDesktopSession: ObservableObject, Identifiable {
    public let id: UUID = .init()
    public let machine: RDMachine
    public let protocolType: RDMachine.RemoteDesktopProtocolType

    @Published public private(set) var phase: RemoteDesktopPhase = .idle
    /// The latest decoded frame, already scaled to the remote framebuffer.
    @Published public private(set) var frameImage: CGImage?
    @Published public private(set) var framebufferSize: CGSize = .zero
    @Published public private(set) var desktopName: String = ""
    /// Every display the host reports; empty until a multi-monitor host answers.
    @Published public private(set) var displays: [RemoteDisplayInfo] = []
    @Published public private(set) var selectedDisplayID: Int = 0
    @Published public private(set) var remoteCursor: RemoteCursorInfo?
    /// Measured update rate of the rendered stream.
    @Published public private(set) var fps: Int = 0
    /// Round trip time when the backend measures it.
    @Published public private(set) var rttMs: Int?
    /// What the backend wants shown as a subtitle or progress line.
    @Published public private(set) var statusHint: String = ""
    /// The last clipboard contents the host pushed.
    @Published public private(set) var remoteClipboard: String = ""

    /// Whether a pointer is currently held, tracked here so the view can
    /// render pressed-state affordances without asking the driver.
    @Published public private(set) var pressedButtons: Set<MouseButton> = []

    private var driver: RemoteDesktopDriver?
    private var frameCounter = 0
    private var fpsWindowStart = Date()
    /// Input is dropped while the session is not fully up.
    public var acceptsInput: Bool { phase == .connected }

    public init(machine: RDMachine, protocolType: RDMachine.RemoteDesktopProtocolType) {
        self.machine = machine
        self.protocolType = protocolType
    }

    /// Builds the backend and starts connecting.
    public func connect() {
        guard phase == .idle || phase.isTerminal else { return }
        if let existing = driver {
            existing.stop()
            driver = nil
        }
        guard let made = RemoteDesktopDriverFactory.make(for: machine, session: self) else {
            phase = .failed(protocolType == .none
                ? "This server has no remote desktop configured."
                : "\(protocolType.displayName) is not available in this build.")
            return
        }
        driver = made
        phase = .connecting("Opening connection")
        made.start(session: self)
    }

    /// Tears the session down; called when the page closes or the user taps
    /// disconnect.
    public func disconnect() {
        driver?.stop()
        driver = nil
        if !phase.isTerminal {
            phase = .closed(nil)
        }
    }

    // MARK: - Input (called by the stage view)

    public func pointerMoved(normalizedX: Double, normalizedY: Double) {
        guard acceptsInput else { return }
        driver?.sendPointerMove(normalizedX: normalizedX, normalizedY: normalizedY)
    }

    public func pointerButton(_ button: MouseButton, isDown: Bool, normalizedX: Double, normalizedY: Double) {
        guard acceptsInput else { return }
        if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
        driver?.sendPointerButton(button, isDown: isDown, normalizedX: normalizedX, normalizedY: normalizedY)
    }

    public func scrolled(deltaX: Double, deltaY: Double, normalizedX: Double, normalizedY: Double) {
        guard acceptsInput else { return }
        driver?.sendScroll(deltaX: deltaX, deltaY: deltaY, normalizedX: normalizedX, normalizedY: normalizedY)
    }

    public func keyPressed(keyCode: UInt16, keySym: UInt32?, characters: String, isDown: Bool) {
        guard acceptsInput else { return }
        driver?.sendKey(keyCode: keyCode, keySym: keySym, characters: characters, isDown: isDown)
    }

    public func typeText(_ text: String) {
        guard acceptsInput else { return }
        driver?.sendText(text)
    }

    public func pushClipboard(_ text: String) {
        guard acceptsInput else { return }
        driver?.sendClipboard(text)
    }

    public func switchDisplay(_ displayID: Int) {
        driver?.selectDisplay(displayID)
    }

    public func applyQuality(fps: Int, quality: Int) {
        driver?.updateQuality(fps: fps, quality: quality)
    }

    /// Full redraw; also useful as a "stuck?" nudge.
    public func refresh() {
        driver?.requestKeyframeOrRefresh()
    }

    // MARK: - Driver intake (nonisolated; each lands on the main actor)

    /// Reports where the driver is in its lifetime.
    nonisolated public func reportPhase(_ phase: RemoteDesktopPhase, hint: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.phase = phase
            if let hint { self.statusHint = hint }
        }
    }

    /// Reports a new or updated frame. `frame` may be nil for a metadata-only
    /// update (resize, cursor move).
    nonisolated public func reportFrame(_ frame: CGImage?, size: CGSize, desktopName: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let frame { self.frameImage = frame }
            self.framebufferSize = size
            if let desktopName { self.desktopName = desktopName }
            self.frameCounter += 1
            let now = Date()
            if now.timeIntervalSince(self.fpsWindowStart) >= 1 {
                self.fps = self.frameCounter
                self.frameCounter = 0
                self.fpsWindowStart = now
            }
        }
    }

    /// Reports the displays the host exposes and which is in view.
    nonisolated public func reportDisplays(_ displays: [RemoteDisplayInfo], selected: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.displays = displays
            self.selectedDisplayID = selected
        }
    }

    /// Reports a remote-drawn cursor (nil hides the overlay).
    nonisolated public func reportCursor(_ cursor: RemoteCursorInfo?) {
        Task { @MainActor [weak self] in
            self?.remoteCursor = cursor
        }
    }

    /// Reports a measured round trip.
    nonisolated public func reportRTT(_ ms: Int?) {
        Task { @MainActor [weak self] in
            self?.rttMs = ms
        }
    }

    /// Reports clipboard text arriving from the host.
    nonisolated public func reportRemoteClipboard(_ text: String) {
        Task { @MainActor [weak self] in
            self?.remoteClipboard = text
        }
    }

    /// Reports a single line the backend wants surfaced (progress detail).
    nonisolated public func reportHint(_ text: String) {
        Task { @MainActor [weak self] in
            self?.statusHint = text
        }
    }
}

public extension RemoteDesktopPhase {
    /// Terminal states: the driver will not advance further on its own.
    var isTerminal: Bool {
        switch self {
        case .closed, .failed: return true
        default: return false
        }
    }
}

public extension RDMachine.RemoteDesktopProtocolType {
    var displayName: String {
        switch self {
        case .none: return "None"
        case .vnc: return "VNC"
        case .uuRemote: return "UU Remote"
        }
    }
}
