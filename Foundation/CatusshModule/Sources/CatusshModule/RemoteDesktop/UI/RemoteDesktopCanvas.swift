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

    public init(session: RemoteDesktopSession, keyboardRequests: Int = 0) {
        self.session = session
        self.keyboardRequests = keyboardRequests
    }

    public func makeUIView(context _: Context) -> RemoteDesktopCanvasView {
        let view = RemoteDesktopCanvasView()
        view.session = session
        view.applyFrame(session.frameImage, framebufferSize: session.framebufferSize)
        view.applyCursor(session.remoteCursor)
        return view
    }

    public func updateUIView(_ view: RemoteDesktopCanvasView, context _: Context) {
        view.session = session
        view.applyFrame(session.frameImage, framebufferSize: session.framebufferSize)
        view.applyCursor(session.remoteCursor)
        view.applyKeyboardRequest(keyboardRequests)
    }
}

/// Draws the remote framebuffer and captures local input. UIKit gives both
/// apps the same pointer model: iPadOS trackpads/mice and Mac Catalyst
/// report through `UIHoverGestureRecognizer`, wheel/trackpad scrolls
/// through `UIPanGestureRecognizer` scroll types, and hardware keys
/// through `presses*`; `UIKeyInput` brings up the software keyboard.
public final class RemoteDesktopCanvasView: UIView {
    /// The session receiving input; set by the representable.
    public var session: RemoteDesktopSession?

    private let frameView = UIImageView()
    private let cursorView = UIImageView()
    private var framebufferSize: CGSize = .zero
    private var cursorPosition = CGPoint.zero
    private var cursorPixelSize = CGSize.zero
    private var appliedKeyboardRequests = 0
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    private var lastNormalized = CGPoint(x: 0.5, y: 0.5)
    private var primaryPress: UILongPressGestureRecognizer!
    private var secondaryPress: UITapGestureRecognizer!
    private var tertiaryPress: UITapGestureRecognizer!

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
        frameView.contentMode = .scaleToFill // it is sized to the fit rect already
        frameView.isUserInteractionEnabled = false
        cursorView.isUserInteractionEnabled = false
        cursorView.isHidden = true
        addSubview(frameView)
        addSubview(cursorView)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverMoved(_:)))
        addGestureRecognizer(hover)

        // A zero-duration long press gives real down/drag/up for the
        // primary button on both touch and indirect-pointer input.
        primaryPress = UILongPressGestureRecognizer(target: self, action: #selector(pressRecognized(_:)))
        primaryPress.minimumPressDuration = 0
        primaryPress.allowableMovement = .greatestFiniteMagnitude
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
        if let cursor, cursor.visible, let image = cursor.image {
            cursorView.image = UIImage(cgImage: image)
            cursorView.isHidden = false
            cursorPosition = CGPoint(x: cursor.x, y: cursor.y)
            cursorPixelSize = CGSize(width: max(CGFloat(cursor.width), 1), height: max(CGFloat(cursor.height), 1))
        } else {
            cursorView.isHidden = true
        }
        setNeedsLayout()
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

    public override func layoutSubviews() {
        super.layoutSubviews()
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

    // MARK: - Coordinate mapping

    /// A view point -> normalized framebuffer coordinates (0...1), clamped
    /// so presses near the letterbox edge still land inside the remote
    /// display. Returns nil while there is no framebuffer.
    private func normalizedPoint(_ location: CGPoint) -> CGPoint? {
        let rect = imageRect
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
            _ = becomeFirstResponder()
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
        // translation.y follows the finger/wheel direction: positive under
        // natural scrolling means content pulled down = scroll up, which
        // matches the driver's "positive y = scroll up" contract.
        scrollAccumX += translation.x
        scrollAccumY += translation.y
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

    // MARK: - Keyboard input

    public override var canBecomeFirstResponder: Bool { true }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            forwardKey(key, isDown: true)
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            handled = true
            forwardKey(key, isDown: false)
        }
        if !handled { super.pressesEnded(presses, with: event) }
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

    // MARK: - Software keyboard (UIKeyInput)

    /// Toggles the software keyboard when the request counter changes.
    func applyKeyboardRequest(_ requests: Int) {
        guard requests != appliedKeyboardRequests else { return }
        appliedKeyboardRequests = requests
        if isFirstResponder {
            resignFirstResponder()
        } else {
            _ = becomeFirstResponder()
        }
    }

    public override var inputAccessoryView: UIView? {
        get { keyboardAccessory }
        set {}
    }

    private var keyboardAccessory: UIView {
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
    }

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
        resignFirstResponder()
    }
}

extension RemoteDesktopCanvasView: UIKeyInput {
    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        if text == "\n" || text == "\r" {
            session?.keyPressed(keyCode: 36, keySym: 0xFF0D, characters: "\r", isDown: true)
            session?.keyPressed(keyCode: 36, keySym: 0xFF0D, characters: "\r", isDown: false)
            return
        }
        session?.typeText(text)
    }

    public func deleteBackward() {
        session?.keyPressed(keyCode: 51, keySym: 0xFF08, characters: "\u{7F}", isDown: true)
        session?.keyPressed(keyCode: 51, keySym: 0xFF08, characters: "\u{7F}", isDown: false)
    }
}

extension RemoteDesktopCanvasView: UITextInputTraits {
    public var keyboardType: UIKeyboardType {
        get { .default }
        set {}
    }

    public var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    public var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    public var spellCheckingType: UITextSpellCheckingType {
        get { .no }
        set {}
    }

    public var smartQuotesType: UITextSmartQuotesType {
        get { .no }
        set {}
    }

    public var smartDashesType: UITextSmartDashesType {
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

    public init(session: RemoteDesktopSession, keyboardRequests: Int = 0) {
        self.session = session
        self.keyboardRequests = keyboardRequests
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
