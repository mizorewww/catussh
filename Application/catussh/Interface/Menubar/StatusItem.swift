//
//  StatusItem.swift
//  catussh (macOS)
//
//  Native AppKit NSStatusItem + NSPopover + NSHostingController.
//

import AppKit
import Combine
import CatusshModule
import MachineStatus
import MachineStatusView
import SwiftUI

@MainActor
final class MenubarStatusItem: NSObject, Identifiable, NSPopoverDelegate {
    nonisolated let id: UUID = .init()
    nonisolated var key: String { id.uuidString }

    let machine: RDMachine
    let identity: RDIdentity
    let session: MonitorSession

    var cancellables = Set<AnyCancellable>()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let frames: [NSImage]
    private let idleFrame: NSImage?
    private var popover: NSPopover?
    private var outsideClickMonitor: Any?

    private var frameIndex = 0
    private var currentInterval: Double = 0
    private var animationTimer: Timer?

    static let frameNames = (0 ... 4).map { "cat_frame_\($0)" }
    static let crashFrameName = "cat_frame_crash"

    init(machine: RDMachine, identity: RDIdentity, session: MonitorSession? = nil) {
        self.machine = machine
        self.identity = identity
        self.session = session ?? MonitorSession(machine: machine, identity: identity)
        frames = Self.frameNames.compactMap { name in
            guard let img = NSImage(named: name) else { return nil }
            img.isTemplate = true
            return img
        }
        if let crash = NSImage(named: Self.crashFrameName) {
            crash.isTemplate = true
            idleFrame = crash
        } else {
            idleFrame = nil
        }

        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.toolTip = machine.name
            button.image = idleFrame
        }

        observeSession()
    }

    deinit {
        debugPrint("\(self) \(#function)")
    }

    enum CatSpeed: TimeInterval {
        case light = 0.05
        case fast = 0.1
        case run = 0.25
        case walk = 0.5
        case hang = 1
        case broken = -1
    }

    @objc private func statusButtonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSEvent.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        closePopover()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open catussh", action: #selector(openMainApp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit catussh", action: #selector(quitApp), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openMainApp() {
        MainWindow.show()
    }

    @objc private func quitApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.terminate(nil)
    }

    func updateDisplay(title: String, frameInterval: Double) {
        guard let button = statusItem.button else { return }
        if title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            paragraph.maximumLineHeight = 10
            paragraph.minimumLineHeight = 10
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                    .paragraphStyle: paragraph,
                    .baselineOffset: -5,
                ]
            )
        }
        guard frameInterval != currentInterval else { return }
        currentInterval = frameInterval
        animationTimer?.invalidate()
        animationTimer = nil
        guard frameInterval > 0, !frames.isEmpty else {
            button.image = idleFrame
            return
        }
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceFrame()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        advanceFrame()
    }

    private func advanceFrame() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        statusItem.button?.image = frames[frameIndex]
    }

    func togglePopover() {
        if let popover, popover.isShown {
            closePopover()
            return
        }
        if popover == nil {
            let content = MenubarPopoverView(session: session) { [weak self] in
                self?.closeThisItem()
            } dismiss: { [weak self] in
                self?.closePopover()
            }
            .environmentObject(CatusshStore.shared)
            .environment(\.rxControlsAtRest, true)

            let hosting = NSHostingController(rootView: content)
            let pop = NSPopover()
            pop.behavior = .transient
            pop.contentSize = NSSize(width: MenubarPopoverView.width, height: 610)
            pop.contentViewController = hosting
            pop.delegate = self
            popover = pop
        }
        guard let popover, let button = statusItem.button else { return }
        popover.appearance = NSApp.appearance ?? NSApp.effectiveAppearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePopover()
            }
        }
    }

    func closePopover() {
        popover?.performClose(nil)
        stopWatchingOutsideClicks()
    }

    nonisolated func popoverDidClose(_: Notification) {
        MainActor.assumeIsolated {
            stopWatchingOutsideClicks()
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    func closeThisItem() {
        animationTimer?.invalidate()
        animationTimer = nil
        closePopover()
        NSStatusBar.system.removeStatusItem(statusItem)
        session.shutdown()
        cancellables.removeAll()
        MenubarTool.shared.remove(menubarItem: id)
    }
}

struct MenubarPopoverView: View {
    @ObservedObject var session: MonitorSession
    @EnvironmentObject var store: CatusshStore
    let remove: () -> Void
    let dismiss: () -> Void

    static let width: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, RX.Space.s4)
                .padding(.vertical, RX.Space.s3)
            Hairline()
            ScrollView {
                VStack(spacing: RX.Space.s3) {
                    if session.phase == .connected, session.status.hasData {
                        SystemCard(session: session)
                        ProcessorCard(session: session)
                        MemoryCard(session: session)
                        HStack(spacing: RX.Space.s3) {
                            ThroughputCard(session: session, direction: .receive, height: 128)
                            ThroughputCard(session: session, direction: .transmit, height: 128)
                        }
                        NetworkCard(session: session)
                        DiskCard(session: session)
                        GraphicsCard(session: session)
                    } else {
                        MonitorPlaceholder(session: session)
                    }
                }
                .padding(RX.Space.s3)
            }
            .frame(height: 560)
        }
        .frame(width: Self.width)
        .background(RXWindowBackground().ignoresSafeArea())
    }

    var header: some View {
        let system = session.status.system
        let hostname = system.hostname == session.machine.name ? "" : system.hostname
        let facts = [hostname, system.releaseName, system.uptimeSec > 0 ? "up \(RXFormat.duration(system.uptimeSec))" : ""]
            .filter { !$0.isEmpty }
        return HStack(alignment: .center, spacing: RX.Space.s2) {
            VStack(alignment: .leading, spacing: 2) {
                RedactableText(session.machine.name, redacted: store.machineRedacted == .all)
                    .font(.rxBodyStrong)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(.rxHelp)
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: RX.Space.s2)
            ForEach([ServerTool.terminal, .files, .monitor]) { tool in
                RXIconButton(tool.help, systemImage: tool.systemImage, kind: .plain) {
                    dismiss()
                    MainWindow.show()
                    tool.show(session.machine.id)
                }
            }
            Hairline(vertical: true)
                .frame(height: 16)
            RXIconButton("Remove from Menu Bar", systemImage: "xmark", kind: .plain, action: remove)
        }
    }
}
