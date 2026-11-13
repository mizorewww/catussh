//
//  RemoteDesktopCanvas.swift
//  CatusshModule
//
//  The interactive remote-desktop canvas shared by both apps. Draws the
//  session's frames aspect-fit, overlays the remote cursor when the host
//  draws its own pointer, and turns pointer, wheel and keyboard events
//  into `RemoteDesktopSession` input calls. UIKit and AppKit backends
//  share the same public surface so the SwiftUI stage view stays one
//  implementation.
//

import SwiftUI

#if canImport(UIKit)
import UIKit

/// SwiftUI shell around `RemoteDesktopCanvasView`; the control chrome
/// lives in `RemoteDesktopStageView` above it.
public struct RemoteDesktopCanvas: UIViewRepresentable {
    @ObservedObject public var session: RemoteDesktopSession
    /// Bumped to toggle the software keyboard on platforms that have one.
    public var keyboardRequests: Int
    /// How fingers drive the pointer on a touch screen.
    public var touchMode: RemoteDesktopTouchMode

    public init(session: RemoteDesktopSession, keyboardRequests: Int = 0, touchMode: RemoteDesktopTouchMode = .trackpad) {
        self.session = session
        self.keyboardRequests = keyboardRequests
        self.touchMode = touchMode
    }

    public func makeUIView(context _: Context) -> RemoteDesktopCanvasView {
        let view = RemoteDesktopCanvasView()
        view.session = session
        view.touchMode = touchMode
        // A canvas made again (the page came back) does not bring up the
        // keyboard for requests an earlier one already answered.
        view.syncKeyboardRequests(keyboardRequests)
        view.applyFrame(session.frameImage, framebufferSize: session.framebufferSize)
        view.applyCursor(session.remoteCursor)
        return view
    }

    public func updateUIView(_ view: RemoteDesktopCanvasView, context _: Context) {
        view.session = session
        view.touchMode = touchMode
        view.applyFrame(session.frameImage, framebufferSize: session.framebufferSize)
        view.applyCursor(session.remoteCursor)
        view.applyKeyboardRequest(keyboardRequests)
    }
}

/// Draws the remote framebuffer and captures local input. iPadOS
/// trackpads/mice and Mac Catalyst report through `UIHoverGestureRecognizer`
/// and the press recognizers, wheel/trackpad scrolls through
/// `UIPanGestureRecognizer` scroll types, and hardware keys through
/// `presses*`; all of them point where they are. On a touch screen, fingers
/// go through `RemoteDesktopTouchGestures` (a trackpad by default, or
/// direct touch), and the software keyboard comes up only when asked for.
public final class RemoteDesktopCanvasView: UIView {
    /// The session receiving input; set by the representable.
    public var session: RemoteDesktopSession?
    /// How fingers drive the pointer; a gesture under way is let go of when
    /// it changes.
    public var touchMode: RemoteDesktopTouchMode = .trackpad {
        didSet {
            guard touchMode != oldValue else { return }
            perform(gestures.cancelled())
            gestures.mode = touchMode
        }
    }

    /// Fingers work as on Moonlight on an iPad or iPhone; Mac Catalyst has
    /// no touch screen and keeps its pointer model.
    #if os(iOS) && !targetEnvironment(macCatalyst)
        static let usesTouchGestures = true
    #else
        static let usesTouchGestures = false
    #endif

    private let frameView = UIImageView()
    private let cursorView = UIImageView()
    /// The pointer drawn here on a touch screen when the host draws none:
    /// a finger moving it like a trackpad must see where it is.
    private let localPointerView = UIImageView(image: RemoteDesktopCanvasView.arrow)
    private var framebufferSize: CGSize = .zero
    private var cursorPosition = CGPoint.zero
    private var cursorPixelSize = CGSize.zero
    private var appliedKeyboardRequests = 0
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    /// Where the pointer is, normalized: where a pencil, mouse or finger put
    /// it, and where a trackpad finger moves it from.
    private var lastNormalized = CGPoint(x: 0.5, y: 0.5) {
        didSet { if Self.usesTouchGestures, lastNormalized != oldValue { setNeedsLayout() } }
    }
    private var primaryPress: UILongPressGestureRecognizer!
    private var secondaryPress: UITapGestureRecognizer!
    private var tertiaryPress: UITapGestureRecognizer!
    private var gestures = RemoteDesktopTouchGestures()
    /// The picture's pinch zoom.
    private var viewport = RemoteDesktopViewport()
    /// The text input the software keyboard comes up for. The canvas takes
    /// hardware keys itself and is no text input, so focusing it never
    /// shows a keyboard.
    private let keyboardProxy = RemoteDesktopKeyboardProxy()
    #if os(iOS) && !targetEnvironment(macCatalyst)
        private var pointerInteraction: UIPointerInteraction?
        private let dragFeedback = UIImpactFeedbackGenerator(style: .light)
    #endif

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func commonInit() {
        backgroundColor = .black
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = Self.usesTouchGestures
        frameView.contentMode = .scaleToFill // it is sized to the fit rect already
        frameView.isUserInteractionEnabled = false
        cursorView.isUserInteractionEnabled = false
        cursorView.isHidden = true
        localPointerView.isUserInteractionEnabled = false
        localPointerView.isHidden = true
        addSubview(frameView)
        addSubview(cursorView)
        addSubview(localPointerView)
        keyboardProxy.canvas = self
        keyboardProxy.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        keyboardProxy.isUserInteractionEnabled = false
        addSubview(keyboardProxy)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverMoved(_:)))
        addGestureRecognizer(hover)

        // A zero-duration long press gives real down/drag/up for the
        // primary button on both touch and indirect-pointer input.
        primaryPress = UILongPressGestureRecognizer(target: self, action: #selector(pressRecognized(_:)))
        primaryPress.minimumPressDuration = 0
        primaryPress.allowableMovement = .greatestFiniteMagnitude
        if Self.usesTouchGestures {
            // Fingers are the touch handlers'; a pencil and a mouse or
            // trackpad button press where they are.
            primaryPress.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
                NSNumber(value: UITouch.TouchType.pencil.rawValue),
            ]
        }
        addGestureRecognizer(primaryPress)

        // `buttonMaskRequired` only exists on UITapGestureRecognizer, so
        // right/middle buttons are sent as clicks; secondary-button drags
        // are not reachable through UIKit on Catalyst.
        secondaryPress = UITapGestureRecognizer(target: self, action: #selector(clickRecognized(_:)))
        secondaryPress.buttonMaskRequired = .secondary
        addGestureRecognizer(secondaryPress)

        tertiaryPress = UITapGestureRecognizer(target: self, action: #selector(clickRecognized(_:)))
        // UIEventButtonMask tops out at .secondary; button 3 is the middle click.
        tertiaryPress.buttonMaskRequired = .button(3)
        addGestureRecognizer(tertiaryPress)

        // Scroll wheels and trackpad scrolls arrive as zero-touch pans on
        // both iPadOS and Mac Catalyst.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrollPanned(_:)))
        scroll.allowedScrollTypesMask = [.discrete, .continuous]
        scroll.minimumNumberOfTouches = 0
        scroll.maximumNumberOfTouches = 0
        addGestureRecognizer(scroll)

        #if os(iOS) && !targetEnvironment(macCatalyst)
            let pointer = UIPointerInteraction(delegate: self)
            addInteraction(pointer)
            pointerInteraction = pointer
        #endif
    }

    // MARK: - Frames

    func applyFrame(_ image: CGImage?, framebufferSize: CGSize) {
        self.framebufferSize = framebufferSize
        if let image {
            frameView.image = UIImage(cgImage: image)
        }
        setNeedsLayout()
    }

    func applyCursor(_ cursor: RemoteCursorInfo?) {
        let wasHidden = cursorView.isHidden
        if let cursor, cursor.visible, let image = cursor.image {
            cursorView.image = UIImage(cgImage: image)
            cursorView.isHidden = false
            cursorPosition = CGPoint(x: cursor.x, y: cursor.y)
            cursorPixelSize = CGSize(width: max(CGFloat(cursor.width), 1), height: max(CGFloat(cursor.height), 1))
        } else {
            cursorView.isHidden = true
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
            if wasHidden != cursorView.isHidden { pointerInteraction?.invalidate() }
        #endif
        setNeedsLayout()
    }

    /// The local pointer: an arrow whose tip, the hotspot, is at the
    /// image's top-left, white with a dark edge to show on any picture.
    static let arrow: UIImage = {
        let points: [CGPoint] = [
            .init(x: 0, y: 0), .init(x: 0, y: 17), .init(x: 4.2, y: 13.2), .init(x: 7, y: 19.5),
            .init(x: 9.6, y: 18.4), .init(x: 6.9, y: 12.3), .init(x: 12.5, y: 12.3),
        ]
        let inset: CGFloat = 1.5
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 12.5 + inset * 2, height: 19.5 + inset * 2), format: format).image { context in
            let path = UIBezierPath()
            path.move(to: points[0].applying(.init(translationX: inset, y: inset)))
            for point in points.dropFirst() { path.addLine(to: point.applying(.init(translationX: inset, y: inset))) }
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 1.5
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            UIColor.black.setStroke()
            path.stroke()
            context.cgContext.setShadow(offset: .zero, blur: 0)
            UIColor.white.setFill()
            path.fill()
        }
    }()

    /// The arrow's tip within its image.
    private static let arrowTip = CGPoint(x: 1.5, y: 1.5)

    /// Whether a pointer is drawn on the picture, the host's or ours.
    private var drawsPointer: Bool {
        !cursorView.isHidden || !localPointerView.isHidden
    }

    /// The rect the framebuffer aspect-fits into, in view coordinates.
    var imageRect: CGRect {
        let fb = framebufferSize
        guard fb.width > 0, fb.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / fb.width, bounds.height / fb.height)
        let size = CGSize(width: fb.width * scale, height: fb.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Where the framebuffer is drawn: `imageRect`, pinch-zoomed.
    var displayRect: CGRect {
        viewport.rect(fitting: imageRect, in: bounds)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let rect = displayRect
        frameView.frame = rect
        // Ours only on a touch screen, with a picture, and while the host
        // draws no pointer of its own.
        let showsLocal = Self.usesTouchGestures && cursorView.isHidden && framebufferSize.width > 0 && frameView.image != nil
        if localPointerView.isHidden == showsLocal {
            localPointerView.isHidden = !showsLocal
            #if os(iOS) && !targetEnvironment(macCatalyst)
                pointerInteraction?.invalidate()
            #endif
        }
        if showsLocal {
            let size = localPointerView.image?.size ?? .zero
            localPointerView.frame = CGRect(
                x: rect.minX + lastNormalized.x * rect.width - Self.arrowTip.x,
                y: rect.minY + lastNormalized.y * rect.height - Self.arrowTip.y,
                width: size.width,
                height: size.height
            )
        }
        if !cursorView.isHidden {
            let fb = framebufferSize
            let w = fb.width > 0 ? cursorPixelSize.width * rect.width / fb.width : cursorPixelSize.width
            let h = fb.height > 0 ? cursorPixelSize.height * rect.height / fb.height : cursorPixelSize.height
            cursorView.frame = CGRect(
                x: rect.minX + cursorPosition.x * rect.width,
                y: rect.minY + cursorPosition.y * rect.height,
                width: w,
                height: h
            )
        }
    }

    // MARK: - Coordinate mapping

    /// A view point -> normalized framebuffer coordinates (0...1), clamped
    /// so presses near the letterbox edge still land inside the remote
    /// display. Returns nil while there is no framebuffer.
    private func normalizedPoint(_ location: CGPoint) -> CGPoint? {
        let rect = displayRect
        guard rect.width > 0, rect.height > 0, framebufferSize.width > 0 else { return nil }
        let nx = (location.x - rect.minX) / rect.width
        let ny = (location.y - rect.minY) / rect.height
        guard nx >= -0.05, nx <= 1.05, ny >= -0.05, ny <= 1.05 else { return nil }
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }

    // MARK: - Pointer input

    @objc private func hoverMoved(_ recognizer: UIHoverGestureRecognizer) {
        guard let point = normalizedPoint(recognizer.location(in: self)) else { return }
        switch recognizer.state {
        case .began, .changed:
            lastNormalized = point
            session?.pointerMoved(normalizedX: point.x, normalizedY: point.y)
        default:
            break
        }
    }

    @objc private func pressRecognized(_ recognizer: UILongPressGestureRecognizer) {
        let point = normalizedPoint(recognizer.location(in: self)) ?? lastNormalized
        switch recognizer.state {
        case .began:
            takeKeyFocus()
            lastNormalized = point
            session?.pointerButton(.left, isDown: true, normalizedX: point.x, normalizedY: point.y)
        case .changed:
            lastNormalized = point
            session?.pointerMoved(normalizedX: point.x, normalizedY: point.y)
        case .ended, .cancelled:
            session?.pointerButton(.left, isDown: false, normalizedX: point.x, normalizedY: point.y)
        default:
            break
        }
    }

    /// Secondary/tertiary buttons: taps send down+up so context menus work.
    @objc private func clickRecognized(_ recognizer: UITapGestureRecognizer) {
        let button: MouseButton = recognizer === tertiaryPress ? .middle : .right
        guard let point = normalizedPoint(recognizer.location(in: self)) else { return }
        session?.pointerButton(button, isDown: true, normalizedX: point.x, normalizedY: point.y)
        session?.pointerButton(button, isDown: false, normalizedX: point.x, normalizedY: point.y)
    }

    @objc private func scrollPanned(_ recognizer: UIPanGestureRecognizer) {
        guard let point = normalizedPoint(recognizer.location(in: self)) else { return }
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        if recognizer.state == .began {
            scrollAccumX = 0
            scrollAccumY = 0
        }
        scroll(by: CGVector(dx: translation.x, dy: translation.y), at: point)
    }

    /// Turns a scroll of `delta` view points into wheel ticks at `point`.
    /// `delta.dy` follows the finger/wheel direction: positive under natural
    /// scrolling means content pulled down = scroll up, which matches the
    /// driver's "positive y = scroll up" contract.
    private func scroll(by delta: CGVector, at point: CGPoint) {
        scrollAccumX += delta.dx
        scrollAccumY += delta.dy
        var dx: Double = 0
        var dy: Double = 0
        let tickPx: CGFloat = 28
        while scrollAccumX >= tickPx { dx += 1; scrollAccumX -= tickPx }
        while scrollAccumX <= -tickPx { dx -= 1; scrollAccumX += tickPx }
        while scrollAccumY >= tickPx { dy += 1; scrollAccumY -= tickPx }
        while scrollAccumY <= -tickPx { dy -= 1; scrollAccumY += tickPx }
        guard dx != 0 || dy != 0 else { return }
        session?.scrolled(deltaX: dx, deltaY: dy, normalizedX: point.x, normalizedY: point.y)
    }

    // MARK: - Touch input

    /// The fingers among `touches`, by a stable id, where they are now. A
    /// pencil and an indirect pointer are the recognizers'.
    private func fingers(_ touches: Set<UITouch>) -> [Int: CGPoint] {
        guard Self.usesTouchGestures else { return [:] }
        var fingers: [Int: CGPoint] = [:]
        for touch in touches where touch.type == .direct {
            fingers[ObjectIdentifier(touch).hashValue] = touch.location(in: self)
        }
        return fingers
    }

    private func now(_ event: UIEvent?) -> TimeInterval {
        event?.timestamp ?? ProcessInfo.processInfo.systemUptime
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = fingers(touches)
        guard !fingers.isEmpty else { return super.touchesBegan(touches, with: event) }
        takeKeyFocus()
        perform(gestures.began(fingers, at: now(event)))
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = fingers(touches)
        guard !fingers.isEmpty else { return super.touchesMoved(touches, with: event) }
        perform(gestures.moved(fingers, at: now(event)))
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = fingers(touches)
        guard !fingers.isEmpty else { return super.touchesEnded(touches, with: event) }
        perform(gestures.ended(Array(fingers.keys), at: now(event)))
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = fingers(touches)
        guard !fingers.isEmpty else { return super.touchesCancelled(touches, with: event) }
        perform(gestures.cancelled())
    }

    /// Carries out what the touch gestures asked for.
    private func perform(_ actions: [RemoteDesktopTouchAction]) {
        for action in actions {
            switch action {
            case let .movePointer(by: delta):
                let rect = displayRect
                guard rect.width > 0, rect.height > 0, framebufferSize.width > 0 else { continue }
                lastNormalized = CGPoint(
                    x: min(max(lastNormalized.x + delta.dx / rect.width, 0), 1),
                    y: min(max(lastNormalized.y + delta.dy / rect.height, 0), 1)
                )
                session?.pointerMoved(normalizedX: lastNormalized.x, normalizedY: lastNormalized.y)
                // Zoomed in, the picture follows the pointer.
                if viewport.zoom > 1 {
                    viewport.reveal(lastNormalized, margin: 48, base: imageRect, bounds: bounds)
                    setNeedsLayout()
                }
            case let .placePointer(at: location):
                // The finger may be on the letterbox: the nearest edge.
                let rect = displayRect
                guard rect.width > 0, rect.height > 0, framebufferSize.width > 0 else { continue }
                lastNormalized = CGPoint(
                    x: min(max((location.x - rect.minX) / rect.width, 0), 1),
                    y: min(max((location.y - rect.minY) / rect.height, 0), 1)
                )
                session?.pointerMoved(normalizedX: lastNormalized.x, normalizedY: lastNormalized.y)
            case let .button(button, isDown):
                #if os(iOS) && !targetEnvironment(macCatalyst)
                    if isDown { dragFeedback.impactOccurred() }
                #endif
                session?.pointerButton(button, isDown: isDown, normalizedX: lastNormalized.x, normalizedY: lastNormalized.y)
            case let .click(button):
                session?.pointerButton(button, isDown: true, normalizedX: lastNormalized.x, normalizedY: lastNormalized.y)
                session?.pointerButton(button, isDown: false, normalizedX: lastNormalized.x, normalizedY: lastNormalized.y)
            case let .scroll(by: delta):
                scroll(by: delta, at: lastNormalized)
            case let .zoom(scale, anchor, pan):
                viewport.zoom(by: scale, anchor: anchor, pan: pan, base: imageRect, bounds: bounds)
                setNeedsLayout()
            case .toggleKeyboard:
                toggleKeyboard()
            }
        }
    }

    // MARK: - Keyboard input

    public override var canBecomeFirstResponder: Bool { true }

    #if os(iOS) && !targetEnvironment(macCatalyst)
        /// Three fingers are the desktop's: no undo or copy and paste bar.
        public override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

        /// Shown, the canvas takes hardware keys at once; it is no text
        /// input, so no software keyboard comes with it.
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.takeKeyFocus() }
        }
    #endif

    /// Takes hardware keys, unless the software keyboard is up: its proxy
    /// has them then.
    private func takeKeyFocus() {
        guard !isFirstResponder, !keyboardProxy.isFirstResponder else { return }
        _ = becomeFirstResponder()
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardPresses(presses, isDown: true) { super.pressesBegan(presses, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardPresses(presses, isDown: false) { super.pressesEnded(presses, with: event) }
    }

    /// Sends the keys among `presses`; false when there were none.
    func forwardPresses(_ presses: Set<UIPress>, isDown: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            forwardKey(key, isDown: isDown)
        }
        return handled
    }

    /// Turns a `UIKey` into either typed text (printable keys without
    /// Ctrl/Alt/Command, so IME-composed characters land intact on the
    /// host) or a key event both drivers understand.
    private func forwardKey(_ key: UIKey, isDown: Bool) {
        guard let session else { return }
        let characters = key.characters
        let modifiers = key.modifierFlags
        if !characters.isEmpty,
           !modifiers.contains(.control), !modifiers.contains(.command), !modifiers.contains(.alternate)
        {
            if isDown { session.typeText(characters) }
            return
        }
        let keyCode = RemoteDesktopKeymap.carbonKeyCode(for: key) ?? UInt16(truncatingIfNeeded: key.keyCode.rawValue)
        let keySym = VNCKeySyms.keySym(forKeyCode: keyCode, characters: characters)
        session.keyPressed(keyCode: keyCode, keySym: keySym, characters: characters, isDown: isDown)
    }

    // MARK: - Software keyboard

    /// Toggles the software keyboard when the request counter changes.
    func applyKeyboardRequest(_ requests: Int) {
        guard requests != appliedKeyboardRequests else { return }
        appliedKeyboardRequests = requests
        toggleKeyboard()
    }

    /// Takes `requests` as answered, without touching the keyboard.
    func syncKeyboardRequests(_ requests: Int) {
        appliedKeyboardRequests = requests
    }

    /// Brings the software keyboard up (its proxy takes focus), or puts it
    /// away and takes hardware keys again.
    func toggleKeyboard() {
        if keyboardProxy.isFirstResponder {
            _ = keyboardProxy.resignFirstResponder()
            _ = becomeFirstResponder()
        } else {
            _ = keyboardProxy.becomeFirstResponder()
        }
    }

    /// Esc, Tab, the arrows and Done over the software keyboard.
    fileprivate lazy var keyboardAccessory: UIView = {
        let bar = UIToolbar()
        bar.sizeToFit()
        let space = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        func item(_ title: String, _ selector: Selector) -> UIBarButtonItem {
            UIBarButtonItem(title: title, style: .plain, target: self, action: selector)
        }
        bar.items = [
            item("Esc", #selector(accessoryEscape)),
            item("Tab", #selector(accessoryTab)),
            item("◀︎", #selector(accessoryLeft)),
            item("▲", #selector(accessoryUp)),
            item("▼", #selector(accessoryDown)),
            item("▶︎", #selector(accessoryRight)),
            space,
            item("Done", #selector(accessoryDone)),
        ]
        return bar
    }()

    @objc private func accessoryEscape() {
        session?.keyPressed(keyCode: 53, keySym: 0xFF1B, characters: "\u{1B}", isDown: true)
        session?.keyPressed(keyCode: 53, keySym: 0xFF1B, characters: "\u{1B}", isDown: false)
    }

    @objc private func accessoryTab() {
        session?.keyPressed(keyCode: 48, keySym: 0xFF09, characters: "\t", isDown: true)
        session?.keyPressed(keyCode: 48, keySym: 0xFF09, characters: "\t", isDown: false)
    }

    @objc private func accessoryLeft() { accessoryArrow(123, sym: 0xFF51) }
    @objc private func accessoryUp() { accessoryArrow(126, sym: 0xFF52) }
    @objc private func accessoryDown() { accessoryArrow(125, sym: 0xFF54) }
    @objc private func accessoryRight() { accessoryArrow(124, sym: 0xFF53) }

    private func accessoryArrow(_ code: UInt16, sym: UInt32) {
        session?.keyPressed(keyCode: code, keySym: sym, characters: "", isDown: true)
        session?.keyPressed(keyCode: code, keySym: sym, characters: "", isDown: false)
    }

    @objc private func accessoryDone() {
        if keyboardProxy.isFirstResponder { toggleKeyboard() }
    }

    /// Text from the software keyboard.
    fileprivate func insertTyped(_ text: String) {
        if text == "\n" || text == "\r" {
            session?.keyPressed(keyCode: 36, keySym: 0xFF0D, characters: "\r", isDown: true)
            session?.keyPressed(keyCode: 36, keySym: 0xFF0D, characters: "\r", isDown: false)
            return
        }
        session?.typeText(text)
    }

    fileprivate func deleteTypedBackward() {
        session?.keyPressed(keyCode: 51, keySym: 0xFF08, characters: "\u{7F}", isDown: true)
        session?.keyPressed(keyCode: 51, keySym: 0xFF08, characters: "\u{7F}", isDown: false)
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
    extension RemoteDesktopCanvasView: UIPointerInteractionDelegate {
        /// A pointer is drawn over the picture (the host's, or ours): the
        /// iPad's own would be a second one. The host's drawn off the view
        /// shows nothing, so the iPad's stays then.
        public func pointerInteraction(_: UIPointerInteraction, styleFor _: UIPointerRegion) -> UIPointerStyle? {
            guard drawsPointer else { return nil }
            if !cursorView.isHidden, !bounds.intersects(cursorView.frame) { return nil }
            return .hidden()
        }
    }
#endif

/// The text input the software keyboard comes up for, a point in the
/// canvas's corner. It hands what is typed (and hardware keys, while it has
/// focus) to the canvas.
private final class RemoteDesktopKeyboardProxy: UIView, UIKeyInput, UITextInputTraits {
    weak var canvas: RemoteDesktopCanvasView?

    override var canBecomeFirstResponder: Bool { true }

    override var inputAccessoryView: UIView? {
        canvas?.keyboardAccessory
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
        override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    #endif

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if canvas?.forwardPresses(presses, isDown: true) != true { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if canvas?.forwardPresses(presses, isDown: false) != true { super.pressesEnded(presses, with: event) }
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        canvas?.insertTyped(text)
    }

    func deleteBackward() {
        canvas?.deleteTypedBackward()
    }

    var keyboardType: UIKeyboardType {
        get { .default }
        set {}
    }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    var smartDashesType: UITextSmartDashesType {
        get { .no }
        set {}
    }
}

#elseif canImport(AppKit)
import AppKit

/// SwiftUI shell around `RemoteDesktopCanvasNSView` on native macOS.
public struct RemoteDesktopCanvas: NSViewRepresentable {
    @ObservedObject public var session: RemoteDesktopSession
    public var keyboardRequests: Int
    /// A Mac has no touch screen: kept for the shared stage only.
    public var touchMode: RemoteDesktopTouchMode

    public init(session: RemoteDesktopSession, keyboardRequests: Int = 0, touchMode: RemoteDesktopTouchMode = .trackpad) {
        self.session = session
        self.keyboardRequests = keyboardRequests
        self.touchMode = touchMode
    }

    public func makeNSView(context _: Context) -> RemoteDesktopCanvasNSView {
        let view = RemoteDesktopCanvasNSView()
        view.session = session
        view.applyFrame(session.frameImage, framebufferSize: session.framebufferSize)
        view.applyCursor(session.remoteCursor)
        return view
    }

    public func updateNSView(_ view: RemoteDesktopCanvasNSView, context _: Context) {
        view.session = session
        view.applyFrame(session.frameImage, framebufferSize: session.framebufferSize)
        view.applyCursor(session.remoteCursor)
    }
}

/// AppKit backend: `mouseMoved` via a tracking area, button events from
/// the responder chain, `scrollWheel` deltas, and `keyDown`/`flagsChanged`
/// which already report Carbon virtual keycodes.
public final class RemoteDesktopCanvasNSView: NSView {
    public var session: RemoteDesktopSession?

    private let frameView = NSImageView()
    private let cursorView = NSImageView()
    private var framebufferSize: CGSize = .zero
    private var cursorPosition = CGPoint.zero
    private var cursorPixelSize = CGSize.zero
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    private var lastNormalized = CGPoint(x: 0.5, y: 0.5)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        frameView.imageScaling = .scaleAxesIndependently
        addSubview(frameView)
        cursorView.isHidden = true
        addSubview(cursorView)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    func applyFrame(_ image: CGImage?, framebufferSize: CGSize) {
        self.framebufferSize = framebufferSize
        if let image {
            frameView.image = NSImage(cgImage: image, size: .zero)
        }
        needsLayout = true
    }

    func applyCursor(_ cursor: RemoteCursorInfo?) {
        if let cursor, cursor.visible, let image = cursor.image {
            cursorView.image = NSImage(cgImage: image, size: .zero)
            cursorView.isHidden = false
            cursorPosition = CGPoint(x: cursor.x, y: cursor.y)
            cursorPixelSize = CGSize(width: max(CGFloat(cursor.width), 1), height: max(CGFloat(cursor.height), 1))
        } else {
            cursorView.isHidden = true
        }
        needsLayout = true
    }

    var imageRect: CGRect {
        let fb = framebufferSize
        guard fb.width > 0, fb.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / fb.width, bounds.height / fb.height)
        let size = CGSize(width: fb.width * scale, height: fb.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    public override func layout() {
        super.layout()
        frameView.frame = imageRect
        if !cursorView.isHidden {
            let rect = imageRect
            let fb = framebufferSize
            let w = fb.width > 0 ? cursorPixelSize.width * rect.width / fb.width : cursorPixelSize.width
            let h = fb.height > 0 ? cursorPixelSize.height * rect.height / fb.height : cursorPixelSize.height
            cursorView.frame = CGRect(
                x: rect.minX + cursorPosition.x * rect.width,
                y: rect.minY + cursorPosition.y * rect.height,
                width: w,
                height: h
            )
        }
    }

    private func normalizedPoint(_ event: NSEvent) -> CGPoint? {
        let location = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, framebufferSize.width > 0 else { return nil }
        let nx = (location.x - rect.minX) / rect.width
        let ny = (location.y - rect.minY) / rect.height
        guard nx >= -0.05, nx <= 1.05, ny >= -0.05, ny <= 1.05 else { return nil }
        return CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let point = normalizedPoint(event) else { return }
        lastNormalized = point
        session?.pointerMoved(normalizedX: point.x, normalizedY: point.y)
    }

    private func buttonEvent(_ button: MouseButton, isDown: Bool, event: NSEvent) {
        let point = normalizedPoint(event) ?? lastNormalized
        window?.makeFirstResponder(self)
        session?.pointerButton(button, isDown: isDown, normalizedX: point.x, normalizedY: point.y)
    }

    private func dragEvent(_ event: NSEvent) {
        guard let point = normalizedPoint(event) else { return }
        lastNormalized = point
        session?.pointerMoved(normalizedX: point.x, normalizedY: point.y)
    }

    public override func mouseDown(with event: NSEvent) { buttonEvent(.left, isDown: true, event: event) }
    public override func mouseUp(with event: NSEvent) { buttonEvent(.left, isDown: false, event: event) }
    public override func mouseDragged(with event: NSEvent) { dragEvent(event) }
    public override func rightMouseDown(with event: NSEvent) { buttonEvent(.right, isDown: true, event: event) }
    public override func rightMouseUp(with event: NSEvent) { buttonEvent(.right, isDown: false, event: event) }
    public override func rightMouseDragged(with event: NSEvent) { dragEvent(event) }
    public override func otherMouseDown(with event: NSEvent) {
        buttonEvent(event.buttonNumber == 2 ? .middle : event.buttonNumber == 3 ? .back : .forward, isDown: true, event: event)
    }
    public override func otherMouseUp(with event: NSEvent) {
        buttonEvent(event.buttonNumber == 2 ? .middle : event.buttonNumber == 3 ? .back : .forward, isDown: false, event: event)
    }
    public override func otherMouseDragged(with event: NSEvent) { dragEvent(event) }

    public override func scrollWheel(with event: NSEvent) {
        guard let point = normalizedPoint(event) else { return }
        // `deltaY > 0` is scroll up in NSEvent, matching the driver
        // contract; precise trackpad deltas accumulate into wheel ticks.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 28 : 1
        scrollAccumX += event.scrollingDeltaX * scale
        scrollAccumY += event.scrollingDeltaY * scale
        var dx: Double = 0
        var dy: Double = 0
        while scrollAccumX >= 28 { dx += 1; scrollAccumX -= 28 }
        while scrollAccumX <= -28 { dx -= 1; scrollAccumX += 28 }
        while scrollAccumY >= 28 { dy += 1; scrollAccumY -= 28 }
        while scrollAccumY <= -28 { dy -= 1; scrollAccumY += 28 }
        guard dx != 0 || dy != 0 else { return }
        session?.scrolled(deltaX: dx, deltaY: dy, normalizedX: point.x, normalizedY: point.y)
    }

    public override func keyDown(with event: NSEvent) {
        forward(event, isDown: true)
    }

    public override func keyUp(with event: NSEvent) {
        forward(event, isDown: false)
    }

    /// Modifier transitions come through `flagsChanged`, not `keyDown`.
    public override func flagsChanged(with event: NSEvent) {
        let keyCode = event.keyCode
        let down: Bool = switch keyCode {
        case 56, 60: event.modifierFlags.contains(.shift)
        case 58, 61: event.modifierFlags.contains(.option)
        case 59, 62: event.modifierFlags.contains(.control)
        case 55, 54: event.modifierFlags.contains(.command)
        case 57: event.modifierFlags.contains(.capsLock)
        default: false
        }
        let characters = event.characters ?? ""
        let keySym = VNCKeySyms.keySym(forKeyCode: keyCode, characters: characters)
        session?.keyPressed(keyCode: keyCode, keySym: keySym, characters: characters, isDown: down)
    }

    private func forward(_ event: NSEvent, isDown: Bool) {
        guard let session else { return }
        let characters = event.characters ?? ""
        let modifiers = event.modifierFlags
        if !characters.isEmpty,
           !modifiers.contains(.control), !modifiers.contains(.command), !modifiers.contains(.option)
        {
            if isDown { session.typeText(characters) }
            return
        }
        let keySym = VNCKeySyms.keySym(forKeyCode: event.keyCode, characters: characters)
        session.keyPressed(keyCode: event.keyCode, keySym: keySym, characters: characters, isDown: isDown)
    }

    /// Text input from the IME path (NSView is a text-input client through
    /// `NSTextInputClient` defaults; plain `keyDown` covers ASCII).
    public override func insertText(_ insertString: Any) {
        if let string = insertString as? String {
            session?.typeText(string)
        }
    }

    public override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)):
            session?.keyPressed(keyCode: 51, keySym: 0xFF08, characters: "\u{7F}", isDown: true)
            session?.keyPressed(keyCode: 51, keySym: 0xFF08, characters: "\u{7F}", isDown: false)
        case #selector(NSResponder.deleteForward(_:)):
            session?.keyPressed(keyCode: 117, keySym: 0xFFFF, characters: "", isDown: true)
            session?.keyPressed(keyCode: 117, keySym: 0xFFFF, characters: "", isDown: false)
        case #selector(NSResponder.insertNewline(_:)):
            session?.keyPressed(keyCode: 36, keySym: 0xFF0D, characters: "\r", isDown: true)
            session?.keyPressed(keyCode: 36, keySym: 0xFF0D, characters: "\r", isDown: false)
        default:
            super.doCommand(by: selector)
        }
    }
}
#endif
