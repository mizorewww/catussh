import GhosttyTerminal
import SwiftUI

#if os(macOS)
    import AppKit

    /// Ghostty's native terminal view on this platform.
    public typealias PlatformTerminalView = AppTerminalView
#else
    import UIKit

    public typealias PlatformTerminalView = UITerminalView
#endif

    /// One native terminal per SSH context. Copies of this SwiftUI value share the
/// same view/session, preserving scrollback when a terminal moves between windows.
public struct CatusshTerminalView: Sendable {
    nonisolated let session: CatusshTerminalSession

    nonisolated public init() { session = CatusshTerminalSession() }

    nonisolated public func write(_ string: String) { session.output.write(Data(string.utf8)) }

    nonisolated public func setTerminalFontSize(with size: Int, preferConfigured: Bool = false) {
        session.callbacks.setFontSize(size)
        let session = session
        DispatchQueue.main.async { session.applyFontSize(preferConfigured: preferConfigured) }
    }

    nonisolated public func requestTerminalSize() -> CGSize { session.callbacks.terminalSize }

    /// For a terminal kept mounted while another page is shown: a hidden
    /// terminal stops rendering and gives up keyboard focus (so typing never
    /// lands in a session you can't see); shown again, it takes focus back.
    @MainActor public func setActive(_ active: Bool) { session.setActive(active) }

    @discardableResult
    nonisolated public func setupBufferChain(callback: ((String) -> Void)?) -> Self {
        session.callbacks.setInput(callback)
        return self
    }

    @discardableResult
    nonisolated public func setupTitleChain(callback: ((String) -> Void)?) -> Self {
        session.callbacks.setTitle(callback)
        return self
    }

    @discardableResult
    nonisolated public func setupBellChain(callback: (() -> Void)?) -> Self {
        session.callbacks.setBell(callback)
        return self
    }

    @discardableResult
    nonisolated public func setupSizeChain(callback: ((CGSize) -> Void)?) -> Self {
        session.callbacks.setResize(callback)
        return self
    }
}

#if os(macOS)
    extension CatusshTerminalView: NSViewRepresentable {
        public func makeNSView(context _: Context) -> AppTerminalView { session.platformView() }
        public func updateNSView(_: AppTerminalView, context _: Context) {}
    }
#else
    extension CatusshTerminalView: UIViewRepresentable {
        public func makeUIView(context _: Context) -> UITerminalView { session.platformView() }
        public func updateUIView(_: UITerminalView, context _: Context) {}
    }
#endif

/// Bridges the shared terminal session core to `CatusshTerminalView`.
public final class TerminalSurfaceBridge: @unchecked Sendable {
    public let termInterface = CatusshTerminalView()

    public init() {}

    public func write(_ string: String) {
        termInterface.write(string)
    }

    public func setupBellChain(_ callback: @escaping () -> Void) {
        termInterface.setupBellChain(callback: callback)
    }

    public func setupBufferChain(_ callback: @escaping (String) -> Void) {
        termInterface.setupBufferChain(callback: callback)
    }

    public func setupTitleChain(_ callback: @escaping (String) -> Void) {
        termInterface.setupTitleChain(callback: callback)
    }

    public func setupSizeChain(_ callback: @escaping (CGSize) -> Void) {
        termInterface.setupSizeChain(callback: callback)
    }
}

/// Only the immutable/thread-safe transport objects cross queues. AppKit storage
/// and all Ghostty view operations are explicitly main-actor isolated.
final class CatusshTerminalSession: @unchecked Sendable {
    let callbacks: TerminalCallbacks
    let backend: InMemoryTerminalSession
    let output: TerminalOutputBuffer
    @MainActor private var presentation: TerminalPresentation?

    init() {
        let callbacks = TerminalCallbacks()
        self.callbacks = callbacks
        let backend = InMemoryTerminalSession(
            write: { callbacks.receiveInput($0) },
            resize: { callbacks.receiveSize(columns: Int($0.columns), rows: Int($0.rows)) }
        )
        self.backend = backend
        output = TerminalOutputBuffer { backend.receive($0) }
    }

    @MainActor func platformView() -> PlatformTerminalView {
        if let presentation { return presentation.view }
        let presentation = TerminalPresentation(session: self)
        self.presentation = presentation
        return presentation.view
    }

    @MainActor func applyFontSize(preferConfigured: Bool) { presentation?.applyFontSize(preferConfigured: preferConfigured) }

    @MainActor func setActive(_ active: Bool) {
        let view = platformView()
        view.setSurfaceVisible(active)
        #if os(macOS)
            if active {
                // After SwiftUI has shown the page, so the view is in its window.
                DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            } else if view.window?.firstResponder === view {
                view.window?.makeFirstResponder(nil)
            }
        #elseif targetEnvironment(macCatalyst)
            if active {
                DispatchQueue.main.async { view.becomeFirstResponder() }
            } else if view.isFirstResponder {
                view.resignFirstResponder()
            }
        #else
            // Taking focus would raise the software keyboard; only let it go.
            if !active, view.isFirstResponder { view.resignFirstResponder() }
        #endif
    }
}

@MainActor
private final class TerminalPresentation: NSObject, TerminalSurfaceTitleDelegate,
    TerminalSurfaceBellDelegate, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceClipboardConfirmationDelegate
{
    let view: PlatformTerminalView
    private let callbacks: TerminalCallbacks
    private let output: TerminalOutputBuffer
    private var initialFontPreferenceApplied = false
    private var didAttach = false

    // SSH workers may release the last session reference. Ghostty's coordinator
    // requires main-actor teardown, including destruction of this view's fields.
    isolated deinit { NotificationCenter.default.removeObserver(self) }

    init(session: CatusshTerminalSession) {
        callbacks = session.callbacks
        output = session.output
        view = PlatformTerminalView(frame: .zero)
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(configurationDidApply), name: CatusshTerminalConfiguration.didApply, object: nil)
        view.delegate = self
        view.controller = CatusshTerminalConfiguration.controller
        // Never use the default .exec backend: SSH remains owned by catussh.
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session.backend), fontSize: Float(Self.surfaceFontSize(CatusshTerminalConfiguration.appliedFontSize ?? Double(callbacks.fontSize)))
        )
    }

    func applyFontSize(preferConfigured: Bool) {
        if preferConfigured && initialFontPreferenceApplied { return }
        initialFontPreferenceApplied = true
        if preferConfigured { applyConfiguredFontSize(); return }
        // Changing configuration.fontSize would recreate the surface and erase
        // scrollback. A binding action updates the existing surface in place.
        _ = view.performBindingAction("set_font_size:\(Self.surfaceFontSize(Double(callbacks.fontSize)))")
    }

    /// The size to give the surface for a font size in points. Ghostty's UIKit
    /// surface converts points at 96 dpi, as on iOS; on the Mac, Catalyst
    /// included, a point is 1/72 inch, as the AppKit surface takes it.
    static func surfaceFontSize(_ points: Double) -> Double {
        #if targetEnvironment(macCatalyst)
            points * 72 / 96
        #else
            points
        #endif
    }

    @objc private func configurationDidApply() {
        initialFontPreferenceApplied = true
        applyConfiguredFontSize()
    }

    private func applyConfiguredFontSize() {
        let size = CatusshTerminalConfiguration.appliedFontSize ?? Double(callbacks.fontSize)
        _ = view.performBindingAction("set_font_size:\(Self.surfaceFontSize(size))")
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        if !didAttach { applyConfiguredFontSize(); didAttach = true }
        output.setAttached(true)
    }

    func terminalDidDetachSurface() { output.setAttached(false) }
    func terminalDidChangeTitle(_ title: String) { callbacks.receiveTitle(title) }
    func terminalDidRingBell() { callbacks.receiveBell() }

    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        // Preserve user-initiated paste, without granting a remote program
        // implicit permission to read or replace the system clipboard.
        request.respond(allow: request.kind == .paste)
    }
}
