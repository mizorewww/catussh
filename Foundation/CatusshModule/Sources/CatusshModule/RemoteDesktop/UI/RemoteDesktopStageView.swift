//
//  RemoteDesktopStageView.swift
//  CatusshModule
//
//  The remote-desktop stage shared by the macOS session page and the iOS
//  modal: the canvas, a floating control bar, and the status overlays for
//  connecting / closed / failed phases.
//

import CatusshDesign
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// A key-combination entry in the stage's Special Keys menu: the strokes
/// are replayed verbatim (modifier down, key click, modifiers up).
public struct RemoteDesktopKeyStroke: Sendable {
    public let keyCode: UInt16
    public let keySym: UInt32?
    public let characters: String
    public let isDown: Bool

    public init(keyCode: UInt16, keySym: UInt32?, characters: String = "", isDown: Bool) {
        self.keyCode = keyCode
        self.keySym = keySym
        self.characters = characters
        self.isDown = isDown
    }
}

/// Special-key sequences every target understands, encoded as Carbon
/// keycodes (macOS targets) plus X11 KeySyms (VNC). Windows UU targets get
/// the Carbon codes translated by the driver.
public enum RemoteDesktopSpecialKeys {
    public static let escape = RemoteDesktopKeyStroke(keyCode: 53, keySym: 0xFF1B, isDown: true)
    public static let tab = RemoteDesktopKeyStroke(keyCode: 48, keySym: 0xFF09, isDown: true)
    public static let backspace = RemoteDesktopKeyStroke(keyCode: 51, keySym: 0xFF08, isDown: true)
    public static let `return` = RemoteDesktopKeyStroke(keyCode: 36, keySym: 0xFF0D, isDown: true)
    public static let deleteForward = RemoteDesktopKeyStroke(keyCode: 117, keySym: 0xFFFF, isDown: true)
    public static let insert = RemoteDesktopKeyStroke(keyCode: 114, keySym: 0xFF63, isDown: true)
    public static let home = RemoteDesktopKeyStroke(keyCode: 115, keySym: 0xFF50, isDown: true)
    public static let end = RemoteDesktopKeyStroke(keyCode: 119, keySym: 0xFF57, isDown: true)
    public static let pageUp = RemoteDesktopKeyStroke(keyCode: 116, keySym: 0xFF55, isDown: true)
    public static let pageDown = RemoteDesktopKeyStroke(keyCode: 121, keySym: 0xFF56, isDown: true)
    public static let left = RemoteDesktopKeyStroke(keyCode: 123, keySym: 0xFF51, isDown: true)
    public static let up = RemoteDesktopKeyStroke(keyCode: 126, keySym: 0xFF52, isDown: true)
    public static let right = RemoteDesktopKeyStroke(keyCode: 124, keySym: 0xFF53, isDown: true)
    public static let down = RemoteDesktopKeyStroke(keyCode: 125, keySym: 0xFF54, isDown: true)

    public static let control = RemoteDesktopKeyStroke(keyCode: 59, keySym: 0xFFE3, isDown: true)
    public static let shift = RemoteDesktopKeyStroke(keyCode: 56, keySym: 0xFFE1, isDown: true)
    public static let alt = RemoteDesktopKeyStroke(keyCode: 58, keySym: 0xFFE9, isDown: true)
    public static let `super` = RemoteDesktopKeyStroke(keyCode: 55, keySym: 0xFFEB, isDown: true)

    /// F1...F12 — Carbon keycodes 122, 120, 99, 118, 96-100, 101, 109, 103, 111.
    public static func functionKey(_ n: Int) -> RemoteDesktopKeyStroke {
        let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        guard n >= 1, n <= 12 else {
            return RemoteDesktopKeyStroke(keyCode: 0, keySym: nil, isDown: true)
        }
        return RemoteDesktopKeyStroke(keyCode: codes[n - 1], keySym: 0xFFBE + UInt32(n - 1), isDown: true)
    }

    /// Ctrl+Alt+Del: the Windows secure attention sequence.
    public static var ctrlAltDelete: [RemoteDesktopKeyStroke] {
        combo([control, alt], deleteForward)
    }

    /// Expands a key into a down+up pair.
    public static func click(_ key: RemoteDesktopKeyStroke) -> [RemoteDesktopKeyStroke] {
        [
            key,
            RemoteDesktopKeyStroke(keyCode: key.keyCode, keySym: key.keySym, characters: key.characters, isDown: false),
        ]
    }

    /// Expands a held-modifier combo into the full down/click/up sequence.
    public static func combo(
        _ modifiers: [RemoteDesktopKeyStroke],
        _ key: RemoteDesktopKeyStroke
    ) -> [RemoteDesktopKeyStroke] {
        modifiers
            + click(key)
            + modifiers.reversed().map {
                RemoteDesktopKeyStroke(keyCode: $0.keyCode, keySym: $0.keySym, isDown: false)
            }
    }
}

/// The stage: a remote canvas plus a floating control bar. Used inside
/// `RemoteDesktopPage` on macOS and the presentation queue on iOS.
public struct RemoteDesktopStageView: View {
    @ObservedObject public var session: RemoteDesktopSession
    /// Optional host-provided close action; rendered as the last control.
    public var onClose: (() -> Void)?

    @State private var keyboardRequests = 0
    @State private var showsTextInput = false
    @State private var textDraft = ""
    @State private var toast: String?
    /// The touch gestures were explained for this session.
    @State private var gestureHintShown = false
    /// Asked once: the bar is drawn again for every frame, and each ask is
    /// a trip to the system.
    @State private var officialAppInstalled = false
    /// How fingers drive the pointer, kept on this device for every desktop.
    @AppStorage(RemoteDesktopTouchMode.defaultsKey) private var touchModeName = RemoteDesktopTouchMode.trackpad.rawValue

    private var touchMode: RemoteDesktopTouchMode {
        RemoteDesktopTouchMode(rawValue: touchModeName) ?? .trackpad
    }

    public init(session: RemoteDesktopSession, onClose: (() -> Void)? = nil) {
        self.session = session
        self.onClose = onClose
    }

    /// The bar above the screen, never over it; the screen takes the rest.
    public var body: some View {
        VStack(spacing: 0) {
            controlBar
            ZStack { canvasLayer }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .background(Color.black.ignoresSafeArea())
        #if os(iOS)
            .onAppear {
                if session.protocolType == .uuRemote { officialAppInstalled = UULocalBridge.officialAppInstalled }
            }
        #endif
        .overlay(alignment: .bottom) {
            // The stage is black in both appearances: white on a dark
            // capsule, never a material that follows Light mode.
            if let toast {
                Text(toast)
                    .font(.rxCaption)
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
            // Once a session: a UU host going locked and back is no new
            // connection.
            .onChange(of: session.phase == .connected) { connected in
                guard connected, !gestureHintShown else { return }
                gestureHintShown = true
                showGestureHint()
            }
        #endif
    }

    // MARK: - Canvas + status overlays

    @ViewBuilder private var canvasLayer: some View {
        RemoteDesktopCanvas(session: session, keyboardRequests: keyboardRequests, touchMode: touchMode)
        switch session.phase {
        case .connected:
            EmptyView()
        case .idle:
            statusOverlay(symbol: "display", title: "Ready", detail: session.statusHint)
        case let .connecting(detail):
            statusOverlay(
                symbol: "arrow.triangle.2.circlepath",
                title: "Connecting",
                detail: session.statusHint.isEmpty ? detail : session.statusHint,
                spinning: true
            )
        case .authenticating:
            statusOverlay(
                symbol: "lock.shield",
                title: "Authenticating",
                detail: session.statusHint,
                spinning: true
            )
        case let .closed(reason):
            statusOverlay(
                symbol: "display.trianglebadge.exclamationmark",
                title: "Session closed",
                detail: reason ?? session.statusHint,
                reconnectable: true
            )
        case let .failed(message):
            statusOverlay(
                symbol: "exclamationmark.triangle",
                title: "Remote desktop failed",
                detail: session.statusHint.isEmpty ? message : "\(message)\n\(session.statusHint)",
                reconnectable: true
            )
        }
    }

    @ViewBuilder
    private func statusOverlay(
        symbol: String,
        title: String,
        detail: String,
        spinning: Bool = false,
        reconnectable: Bool = false
    ) -> some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 10) {
                if spinning {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                if reconnectable {
                    Button("Reconnect") { session.connect() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }

    // MARK: - Control bar

    /// On a touch screen the bar is taller, every control is a finger-sized
    /// target named under its symbol, and what does not fit scrolls
    /// sideways; More and Close stay at the end. On the Mac Connect and
    /// Close do.
    #if os(iOS) && !targetEnvironment(macCatalyst)
        static let barHeight: CGFloat = 56
        static let controlFont = Font.system(size: 17)
    #else
        static let barHeight: CGFloat = 34
        static let controlFont = Font.system(size: 13)
    #endif

    private var controlBar: some View {
        HStack(spacing: 4) {
            #if os(iOS) && !targetEnvironment(macCatalyst)
                touchStatus
                Divider().frame(height: 28)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) { touchControls }
                        .padding(.trailing, 12)
                }
                // Controls past the edge fade out rather than end cut off:
                // the row scrolls.
                .mask(
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 16)
                    }
                )
                Divider().frame(height: 28)
                moreMenu
            #else
                controls
                Spacer(minLength: 8)
                connectButton
            #endif
            if let onClose {
                Button { onClose() } label: {
                    Label("Close", systemImage: "xmark.circle").stageControl()
                }
                .help("Close this session")
            }
        }
        .buttonStyle(.borderless)
        .font(Self.controlFont)
        .foregroundStyle(Color.rxInk)
        .padding(.horizontal, 10)
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rxSurface)
        .overlay(alignment: .bottom) { Color.rxHairline.frame(height: 1) }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
        /// What the bar's state is, in two short lines: the phase (or the
        /// desktop's name) and the frame rate and round trip.
        private var touchStatus: some View {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    StatusDot(status)
                    Text(phaseTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.rxInk)
                        .lineLimit(1)
                }
                // View only must show: input going nowhere looks broken.
                if session.viewOnly {
                    Label("View only", systemImage: "eye")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.rxAccent)
                        .lineLimit(1)
                } else if !metricsText.isEmpty {
                    Text(metricsText)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color.rxInkSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 104, alignment: .leading)
            .accessibilityElement(children: .combine)
        }

        /// The controls a finger needs at hand, each named under its symbol.
        @ViewBuilder private var touchControls: some View {
            Button { keyboardRequests += 1 } label: {
                Label("Keyboard", systemImage: "keyboard").stageControl()
            }
            specialKeysMenu
            touchModeMenu
            Button { showsTextInput = true } label: {
                Label("Type", systemImage: "textformat").stageControl()
            }
            .popover(isPresented: $showsTextInput) { textInputPopover }
            clipboardMenu
        }

        /// Everything used now and then, by name.
        private var moreMenu: some View {
            Menu {
                if session.phase.isTerminal || session.phase == .idle {
                    Button { session.connect() } label: { Label("Connect", systemImage: "play.circle") }
                } else {
                    Button { session.disconnect() } label: { Label("Disconnect", systemImage: "stop.circle") }
                }
                Button { session.refresh() } label: { Label("Refresh Screen", systemImage: "arrow.clockwise") }
                Toggle(isOn: $session.viewOnly) {
                    Label("View Only", systemImage: "eye")
                }
                if session.displays.count > 1 {
                    Menu {
                        displayChoices
                    } label: {
                        Label("Display", systemImage: "rectangle.on.rectangle")
                    }
                }
                if session.protocolType == .uuRemote {
                    Menu {
                        qualityChoices
                    } label: {
                        Label("Quality", systemImage: "slider.horizontal.3")
                    }
                    Menu {
                        officialAppChoices
                    } label: {
                        Label("UU Remote App", systemImage: "pip")
                    }
                }
                Section {
                    Button { showGestureHint(force: true) } label: { Label("Touch Gestures", systemImage: "hand.tap") }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle").stageControl()
            }
        }

        static let gestureHintsShownKey = "me.mizorewww.rayon.remoteDesktop.gestureHintsShown"

        /// How fingers work, the first few times a desktop connects, or
        /// when asked for.
        private func showGestureHint(force: Bool = false) {
            let defaults = UserDefaults.standard
            let shown = defaults.integer(forKey: Self.gestureHintsShownKey)
            guard force || shown < 3 else { return }
            if !force { defaults.set(shown + 1, forKey: Self.gestureHintsShownKey) }
            let hint = switch touchMode {
            case .trackpad: "Drag to move the pointer · tap to click · two fingers to scroll or right-click · three fingers for the keyboard"
            case .direct: "Tap to click there · hold to right-click · two fingers to scroll · three fingers for the keyboard"
            }
            flash(hint, for: 5)
        }
    #endif

    @ViewBuilder private var controls: some View {
        statusPill
        Divider().frame(height: 16)
        Text(metricsText)
            .font(.rxCaption)
            .foregroundStyle(Color.rxInkSecondary)
            .lineLimit(1)
        Divider().frame(height: 16)
        if session.displays.count > 1 { displayMenu }
        if session.protocolType == .uuRemote { qualityMenu }
        viewOnlyButton
        specialKeysMenu
        Button { showsTextInput = true } label: {
            Label("Type Text", systemImage: "textformat").stageControl()
        }
        .popover(isPresented: $showsTextInput) { textInputPopover }
        #if !targetEnvironment(macCatalyst)
            // A Mac has a keyboard; a touch screen shows one on request.
            Button { keyboardRequests += 1 } label: {
                Label("Software Keyboard", systemImage: "keyboard").stageControl()
            }
            .help("Toggle the software keyboard")
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst)
            touchModeMenu
        #endif
        clipboardMenu
        Button { session.refresh() } label: {
            Label("Refresh Screen", systemImage: "arrow.clockwise").stageControl()
        }
        .help("Ask the host for a full refresh")
        #if !targetEnvironment(macCatalyst)
            if session.protocolType == .uuRemote { officialAppMenu }
        #endif
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            StatusDot(status)
            Text(phaseTitle)
                .font(.rxCaption)
                .foregroundStyle(Color.rxInkSecondary)
        }
    }

    private var status: RXStatus {
        switch session.phase {
        case .connected: .success
        case .idle: .off
        case .connecting, .authenticating: .running
        case .closed: .warning
        case .failed: .danger
        }
    }

    private var phaseTitle: String {
        switch session.phase {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case .authenticating: "Authenticating"
        case .connected: session.desktopName.isEmpty ? "Connected" : session.desktopName
        case .closed: "Closed"
        case .failed: "Failed"
        }
    }

    private var metricsText: String {
        var parts: [String] = []
        if session.fps > 0 { parts.append("\(session.fps) fps") }
        if let rtt = session.rttMs { parts.append("\(rtt) ms") }
        if !session.statusHint.isEmpty, session.phase != .connected {
            parts.append(session.statusHint)
        }
        return parts.joined(separator: " · ")
    }

    private var displayMenu: some View {
        Menu {
            displayChoices
        } label: {
            Label("Display", systemImage: "rectangle.on.rectangle").stageControl()
        }
        .help("Switch display")
    }

    @ViewBuilder private var displayChoices: some View {
            ForEach(session.displays) { display in
                Button {
                    session.switchDisplay(display.id)
                } label: {
                    let title = display.name.isEmpty ? "Display \(display.id)" : display.name
                    if display.id == session.selectedDisplayID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
    }

    private var qualityMenu: some View {
        Menu {
            qualityChoices
        } label: {
            Label("Quality", systemImage: "slider.horizontal.3").stageControl()
        }
        .help("Frame rate and image quality")
    }

    @ViewBuilder private var qualityChoices: some View {
            Section("Frame rate") {
                ForEach([30, 60, 90, 144], id: \.self) { fps in
                    Button {
                        applyQuality(fps: fps)
                    } label: {
                        if fps == session.machine.uuFPS {
                            Label("\(fps) fps", systemImage: "checkmark")
                        } else {
                            Text("\(fps) fps")
                        }
                    }
                }
            }
            Section("Quality") {
                ForEach(Self.qualityPresets, id: \.value) { preset in
                    Button {
                        applyQuality(quality: preset.value)
                    } label: {
                        if preset.value == session.machine.uuQuality {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Text(preset.title)
                        }
                    }
                }
            }
    }

    private static let qualityPresets: [(title: String, value: Int)] = [
        ("Fast", 1),
        ("Balanced", 2),
        ("High", 3),
        ("Ultra", 4),
        ("Auto", 5),
    ]

    private func applyQuality(fps: Int? = nil, quality: Int? = nil) {
        let newFPS = fps ?? session.machine.uuFPS
        let newQuality = quality ?? session.machine.uuQuality
        var machine = session.machine
        machine.uuFPS = newFPS
        machine.uuQuality = newQuality
        CatusshStore.shared.machineGroup[machine.id] = machine
        session.applyQuality(fps: newFPS, quality: newQuality)
    }

    private var specialKeysMenu: some View {
        Menu {
            Button("Esc") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.escape)) }
            Button("Tab") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.tab)) }
            Button("Return") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.return)) }
            Button("Delete ⌦") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.deleteForward)) }
            Divider()
            Button("Ctrl+Alt+Del") { send(RemoteDesktopSpecialKeys.ctrlAltDelete) }
            Button("Alt+Tab") {
                send(RemoteDesktopSpecialKeys.combo(
                    [RemoteDesktopSpecialKeys.alt],
                    RemoteDesktopSpecialKeys.tab
                ))
            }
            Button("Win / Super") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.super)) }
            Divider()
            Menu("Function Keys") {
                ForEach(1 ... 12, id: \.self) { n in
                    Button("F\(n)") {
                        send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.functionKey(n)))
                    }
                }
            }
            Menu("Navigation") {
                Button("Home") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.home)) }
                Button("End") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.end)) }
                Button("Page Up") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.pageUp)) }
                Button("Page Down") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.pageDown)) }
                Button("Insert") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.insert)) }
                Button("Backspace") { send(RemoteDesktopSpecialKeys.click(RemoteDesktopSpecialKeys.backspace)) }
            }
        } label: {
            Label("Keys", systemImage: "command").stageControl()
        }
        .help("Send a special key the local keyboard can not reach")
    }

    private func send(_ strokes: [RemoteDesktopKeyStroke]) {
        session.sendKeys(strokes)
    }

    private var viewOnlyButton: some View {
        Button { session.viewOnly.toggle() } label: {
            Label(session.viewOnly ? "View Only" : "Control", systemImage: session.viewOnly ? "eye" : "cursorarrow.motionlines").stageControl()
                .foregroundStyle(session.viewOnly ? Color.rxAccent : Color.rxInk)
        }
        .help(session.viewOnly ? "View only: input stays local. Click to take control" : "Watch without sending mouse or keys")
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
        /// Trackpad (the pointer moves as far as the finger) or direct touch
        /// (the pointer goes under it). A pencil, mouse or trackpad always
        /// points where it is.
        private var touchModeMenu: some View {
            Menu {
                Section {
                    ForEach(RemoteDesktopTouchMode.allCases, id: \.self) { mode in
                        Button {
                            touchModeName = mode.rawValue
                        } label: {
                            if mode == touchMode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                    }
                }
                Section {
                    switch touchMode {
                    case .trackpad:
                        Text("Drag to move the pointer, tap to click, hold then drag to drag")
                    case .direct:
                        Text("Tap to click there, drag to drag, hold to right-click")
                    }
                    Text("Two fingers: tap to right-click, drag to scroll, pinch to zoom")
                    Text("Three fingers: tap for the keyboard")
                }
            } label: {
                Label(touchMode.title, systemImage: touchMode.systemImage).stageControl()
            }
            .help("How a finger moves the pointer")
        }
    #endif

    private var clipboardMenu: some View {
        Menu {
            Button {
                let text = RemoteDesktopPasteboard.read()
                guard !text.isEmpty else {
                    flash("Pasteboard is empty")
                    return
                }
                session.pushClipboard(text)
                flash("Sent \(text.count) characters to the remote clipboard")
            } label: {
                Label("Push local clipboard", systemImage: "doc.on.clipboard")
            }
            Button {
                let text = session.remoteClipboard
                guard !text.isEmpty else {
                    flash("Remote clipboard is empty")
                    return
                }
                RemoteDesktopPasteboard.write(text)
                flash("Copied \(text.count) characters from the remote clipboard")
            } label: {
                Label("Pull remote clipboard", systemImage: "clipboard")
            }
        } label: {
            Label("Clipboard", systemImage: "clipboard").stageControl()
        }
        .help("Clipboard sync")
    }

    private var officialAppMenu: some View {
        Menu {
            officialAppChoices
        } label: {
            Label("Official App", systemImage: "pip").stageControl()
        }
        .help("Hand off to the official UU Remote app")
    }

    @ViewBuilder private var officialAppChoices: some View {
            #if os(macOS)
            // Mac Catalyst cannot exec uuyc-cli; the official app is opened
            // through its URL scheme or the CLI when it exists.
            if UULocalBridge.cliInstalled || UULocalBridge.officialAppInstalled {
                Button("Open in UU Remote app") {
                    UULocalBridge.openControlInOfficialApp(for: session.machine)
                }
                if UULocalBridge.cliInstalled {
                    Button("Open remote terminal (uuyc-cli)") {
                        try? UULocalBridge.cliTerminal(deviceID: session.machine.uuDeviceID)
                    }
                }
            } else {
                Text("UURemote.app is not installed")
            }
            #else
            if officialAppInstalled {
                Button("Open in UU Remote app (PiP)") {
                    UULocalBridge.openControlInOfficialApp(for: session.machine)
                }
                Button("Re-authorize this device") {
                    UULocalBridge.openAuthorizeInOfficialApp(for: session.machine)
                }
            } else {
                Text("UURemote app is not installed")
            }
            #endif
    }

    private var connectButton: some View {
        Group {
            if session.phase.isTerminal || session.phase == .idle {
                Button { session.connect() } label: {
                    Label("Connect", systemImage: "play.circle").stageControl()
                }
                .help("Connect")
            } else {
                Button { session.disconnect() } label: {
                    Label("Disconnect", systemImage: "stop.circle").stageControl()
                }
                .help("Disconnect")
            }
        }
    }

    private var textInputPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type text on the remote host")
                .font(.rxCaption)
                .foregroundStyle(Color.rxInkSecondary)
            HStack {
                TextField("Text to send", text: $textDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                    .onSubmit { sendDraft() }
                Button("Send") { sendDraft() }
                    .disabled(textDraft.isEmpty)
            }
        }
        .padding(12)
    }

    private func sendDraft() {
        guard !textDraft.isEmpty else { return }
        session.typeText(textDraft)
        textDraft = ""
        showsTextInput = false
    }

    private func flash(_ message: String, for seconds: Double = 2) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            withAnimation {
                if toast == message { toast = nil }
            }
        }
    }
}

private extension Label {
    /// A control of the stage's bar. On the Mac only its symbol, named by its
    /// tooltip; a touch screen has no tooltips, so there its name is written
    /// under the symbol, in a target at least 44 points high.
    func stageControl() -> some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
            labelStyle(StageControlLabelStyle())
        #else
            labelStyle(.iconOnly)
        #endif
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
    /// Symbol over its name.
    private struct StageControlLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            VStack(spacing: 3) {
                configuration.icon
                    .font(.system(size: 18))
                    .frame(height: 22)
                configuration.title
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 52, minHeight: 44)
            .contentShape(Rectangle())
        }
    }
#endif

/// Pasteboard read/write shared by the stage's clipboard actions.
enum RemoteDesktopPasteboard {
    static func read() -> String {
        #if canImport(UIKit)
            return UIPasteboard.general.string ?? ""
        #elseif canImport(AppKit)
            return NSPasteboard.general.string(forType: .string) ?? ""
        #else
            return ""
        #endif
    }

    static func write(_ text: String) {
        #if canImport(UIKit)
            UIPasteboard.general.string = text
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
