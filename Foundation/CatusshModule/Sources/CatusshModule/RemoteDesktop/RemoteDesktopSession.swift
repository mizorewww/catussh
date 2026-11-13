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
import os

@MainActor
public final class RemoteDesktopSession: ObservableObject, Identifiable {
    public let id: UUID = .init()
    public let machine: RDMachine
    public let protocolType: RDMachine.RemoteDesktopProtocolType

    @Published public private(set) var phase: RemoteDesktopPhase = .idle
    /// The latest decoded frame, already scaled to the remote framebuffer.
    /// Not published: a frame redraws the canvas (`onFrame`), not the
    /// controls around it, which are drawn again on every publish.
    public private(set) var frameImage: CGImage?
    @Published public private(set) var framebufferSize: CGSize = .zero
    @Published public private(set) var desktopName: String = ""
    /// Every display the host reports; empty until a multi-monitor host answers.
    @Published public private(set) var displays: [RemoteDisplayInfo] = []
    @Published public private(set) var selectedDisplayID: Int = 0
    /// The host's pointer; not published, it moves with every pointer
    /// move (`onCursor`).
    public private(set) var remoteCursor: RemoteCursorInfo?
    /// Who draws the frames and cursor (canvases; more than one while a
    /// page is shown twice), each held weakly, called on the main actor.
    private var frameObservers: [FrameObserver] = []

    private struct FrameObserver {
        weak var owner: AnyObject?
        let frame: (CGImage?, CGSize) -> Void
        let cursor: (RemoteCursorInfo?) -> Void
    }

    /// `owner`'s calls for every frame and cursor change, until it goes
    /// away or stops; a second call for the same owner replaces the first.
    public func observeFrames(by owner: AnyObject, frame: @escaping (CGImage?, CGSize) -> Void, cursor: @escaping (RemoteCursorInfo?) -> Void) {
        frameObservers.removeAll { $0.owner == nil || $0.owner === owner }
        frameObservers.append(FrameObserver(owner: owner, frame: frame, cursor: cursor))
    }

    public func stopObservingFrames(by owner: AnyObject) {
        frameObservers.removeAll { $0.owner == nil || $0.owner === owner }
    }
    /// Measured update rate of the rendered stream.
    @Published public private(set) var fps: Int = 0
    /// Round trip time when the backend measures it.
    @Published public private(set) var rttMs: Int?
    /// Bit rate, loss and route, when the backend measures them.
    @Published public private(set) var network: RemoteDesktopNetwork?
    /// What the backend wants shown as a subtitle or progress line.
    @Published public private(set) var statusHint: String = ""
    /// The last clipboard contents the host pushed.
    @Published public private(set) var remoteClipboard: String = ""

    /// Whether a pointer is currently held, tracked here so the view can
    /// render pressed-state affordances without asking the driver.
    @Published public private(set) var pressedButtons: Set<MouseButton> = []

    /// Watch without touching: pointer, wheel and keys stay local. Turning
    /// it on lets go of any button or key still held on the host.
    @Published public var viewOnly = false {
        didSet {
            guard viewOnly, !oldValue, phase == .connected else { return }
            let held = pressedButtons
            pressedButtons = []
            for button in held {
                driver?.sendPointerButton(button, isDown: false, normalizedX: lastPointer.x, normalizedY: lastPointer.y)
            }
            let keys = heldKeys
            heldKeys = [:]
            for (keyCode, key) in keys {
                driver?.sendKey(keyCode: keyCode, keySym: key.keySym, characters: key.characters, isDown: false)
            }
        }
    }

    /// Keys sent down and not yet up, so view only can release them.
    private var heldKeys: [UInt16: (keySym: UInt32?, characters: String)] = [:]

    private var driver: RemoteDesktopDriver?
    private var fpsWindowStart = Date()
    /// Frames and cursors from the driver's threads wait here, the latest
    /// of each, for one trip to the main actor at a time: a main thread
    /// that falls behind skips frames instead of queueing them.
    private nonisolated let mailbox = RemoteDesktopMailbox()
    /// Where the pointer was last sent, normalized.
    private var lastPointer = (x: 0.5, y: 0.5)
    /// Input is dropped while the session is not fully up, or while it is
    /// view only. The clipboard is an explicit action and still goes.
    public var acceptsInput: Bool { phase == .connected && !viewOnly }

    /// Phase changes and who ended a session, to tell a dropped connection
    /// from a closed page in the device's log.
    nonisolated static let log = Logger(subsystem: "me.mizorewww.rayon", category: "remote-desktop")

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
        Self.log.info("disconnect \(self.machine.name, privacy: .public) in \(String(describing: self.phase), privacy: .public)")
        driver?.stop()
        driver = nil
        if !phase.isTerminal {
            phase = .closed(nil)
        }
    }

    // MARK: - Input (called by the stage view)

    public func pointerMoved(normalizedX: Double, normalizedY: Double) {
        guard acceptsInput, let (x, y) = Self.onScreen(normalizedX, normalizedY) else { return }
        lastPointer = (x, y)
        driver?.sendPointerMove(normalizedX: x, normalizedY: y)
    }

    public func pointerButton(_ button: MouseButton, isDown: Bool, normalizedX: Double, normalizedY: Double) {
        guard acceptsInput else { return }
        // A position that is no number keeps the last one: a release must
        // still go out.
        let (x, y) = Self.onScreen(normalizedX, normalizedY) ?? lastPointer
        lastPointer = (x, y)
        if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
        driver?.sendPointerButton(button, isDown: isDown, normalizedX: x, normalizedY: y)
    }

    public func scrolled(deltaX: Double, deltaY: Double, normalizedX: Double, normalizedY: Double) {
        guard acceptsInput, deltaX.isFinite, deltaY.isFinite, deltaX != 0 || deltaY != 0 else { return }
        let (x, y) = Self.onScreen(normalizedX, normalizedY) ?? lastPointer
        driver?.sendScroll(deltaX: deltaX, deltaY: deltaY, normalizedX: x, normalizedY: y)
    }

    /// A normalized position clamped onto the screen; nil when it is no
    /// number at all, which no driver may be handed (VNC traps on it).
    nonisolated static func onScreen(_ x: Double, _ y: Double) -> (x: Double, y: Double)? {
        guard x.isFinite, y.isFinite else { return nil }
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    public func keyPressed(keyCode: UInt16, keySym: UInt32?, characters: String, isDown: Bool) {
        guard acceptsInput else { return }
        if isDown { heldKeys[keyCode] = (keySym, characters) } else { heldKeys[keyCode] = nil }
        driver?.sendKey(keyCode: keyCode, keySym: keySym, characters: characters, isDown: isDown)
    }

    public func typeText(_ text: String) {
        guard acceptsInput else { return }
        driver?.sendText(text)
    }

    /// Replays a key sequence (a Special Keys entry, Ctrl+Alt+Del…).
    public func sendKeys(_ strokes: [RemoteDesktopKeyStroke]) {
        for stroke in strokes {
            keyPressed(keyCode: stroke.keyCode, keySym: stroke.keySym, characters: stroke.characters, isDown: stroke.isDown)
        }
    }

    public func pushClipboard(_ text: String) {
        guard phase == .connected else { return }
        driver?.sendClipboard(text)
    }

    public func switchDisplay(_ displayID: Int) {
        driver?.selectDisplay(displayID)
    }

    /// The display after the one in view, round to the first.
    public func nextDisplay() {
        guard displays.count > 1 else { return }
        let index = displays.firstIndex { $0.id == selectedDisplayID } ?? -1
        switchDisplay(displays[(index + 1) % displays.count].id)
    }

    /// Whether the host can be given a display of our own (UU virtual screens).
    public var canAddDisplays: Bool { protocolType == .uuRemote && phase == .connected }

    public func addVirtualDisplay(width: Int, height: Int) {
        guard canAddDisplays else { return }
        driver?.addVirtualDisplay(width: width, height: height)
    }

    public func removeVirtualDisplay(_ displayID: Int) {
        driver?.removeVirtualDisplay(displayID)
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
            if self.phase != phase {
                Self.log.info("\(self.machine.name, privacy: .public): \(String(describing: phase), privacy: .public) \(hint ?? "", privacy: .public)")
                self.phase = phase
            }
            if let hint, hint != self.statusHint { self.statusHint = hint }
        }
    }

    /// Reports a new or updated frame. `frame` may be nil for a metadata-only
    /// update (resize, cursor move).
    nonisolated public func reportFrame(_ frame: CGImage?, size: CGSize, desktopName: String? = nil) {
        if mailbox.post(frame: frame, size: size, desktopName: desktopName) { scheduleDelivery() }
    }

    /// Reports the displays the host exposes and which is in view.
    nonisolated public func reportDisplays(_ displays: [RemoteDisplayInfo], selected: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.displays != displays { self.displays = displays }
            if self.selectedDisplayID != selected { self.selectedDisplayID = selected }
        }
    }

    /// Reports a remote-drawn cursor (nil hides the overlay).
    nonisolated public func reportCursor(_ cursor: RemoteCursorInfo?) {
        if mailbox.post(cursor: cursor) { scheduleDelivery() }
    }

    nonisolated private func scheduleDelivery() {
        Task { @MainActor [weak self] in self?.deliver() }
    }

    /// What the mailbox holds, to the canvas; the frame rate once a second.
    private func deliver() {
        let mail = mailbox.take()
        if let cursor = mail.cursor {
            remoteCursor = cursor
            for observer in frameObservers where observer.owner != nil { observer.cursor(cursor) }
        }
        guard let frame = mail.frame else { return }
        if let image = frame.image { frameImage = image }
        if framebufferSize != frame.size { framebufferSize = frame.size }
        if let name = frame.desktopName, name != desktopName { desktopName = name }
        for observer in frameObservers where observer.owner != nil { observer.frame(frameImage, frame.size) }
        let now = Date()
        if now.timeIntervalSince(fpsWindowStart) >= 1 {
            let counted = mailbox.takeFrameCount()
            let rate = Int((Double(counted) / now.timeIntervalSince(fpsWindowStart)).rounded())
            if rate != fps { fps = rate }
            fpsWindowStart = now
        }
    }

    /// Reports a measured round trip.
    nonisolated public func reportRTT(_ ms: Int?) {
        Task { @MainActor [weak self] in
            guard let self, self.rttMs != ms else { return }
            self.rttMs = ms
        }
    }

    /// Reports the connection's bit rate, loss and route.
    nonisolated public func reportNetwork(_ network: RemoteDesktopNetwork?) {
        Task { @MainActor [weak self] in
            guard let self, self.network != network else { return }
            self.network = network
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
            guard let self, self.statusHint != text else { return }
            self.statusHint = text
        }
    }
}

/// The latest frame and cursor a driver reported, until the main actor
/// takes them; `post` says when a trip there is to be made.
final class RemoteDesktopMailbox: @unchecked Sendable {
    struct Frame {
        var image: CGImage?
        var size: CGSize
        var desktopName: String?
    }

    private let lock = NSLock()
    private var frame: Frame?
    private var cursor: RemoteCursorInfo??
    private var scheduled = false
    private var frameCount = 0

    /// A frame replacing any not yet taken; one without a picture keeps the
    /// waiting one's picture. True when the main actor is to be asked over.
    func post(frame image: CGImage?, size: CGSize, desktopName: String?) -> Bool {
        lock.withLock {
            frameCount += image == nil ? 0 : 1
            frame = Frame(
                image: image ?? frame?.image,
                size: size,
                desktopName: desktopName ?? frame?.desktopName
            )
            return schedule()
        }
    }

    func post(cursor new: RemoteCursorInfo?) -> Bool {
        lock.withLock {
            cursor = .some(new)
            return schedule()
        }
    }

    private func schedule() -> Bool {
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func take() -> (frame: Frame?, cursor: RemoteCursorInfo??) {
        lock.withLock {
            defer {
                frame = nil
                cursor = nil
                scheduled = false
            }
            return (frame, cursor)
        }
    }

    /// Frames posted since the last call, taken or skipped.
    func takeFrameCount() -> Int {
        lock.withLock {
            defer { frameCount = 0 }
            return frameCount
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
