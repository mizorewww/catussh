//
//  TerminalContext.swift
//  CatusshModule
//
//  Shared SSH terminal session context, previously duplicated between the
//  macOS and iOS apps. The renderer stays in the apps and is injected as a
//  TerminalSessionSurface; interface presentation goes through
//  TerminalInterface.
//

import Foundation
import NSRemoteShell
import SwiftUI

/// The terminal renderer a session drives, implemented in the apps over
/// CatusshTerminalView so CatusshModule never links the renderer.
public protocol TerminalSessionSurface: AnyObject {
    func write(_ string: String)
    func setupBellChain(_ callback: @escaping () -> Void)
    func setupBufferChain(_ callback: @escaping (String) -> Void)
    func setupTitleChain(_ callback: @escaping (String) -> Void)
    func setupSizeChain(_ callback: @escaping (CGSize) -> Void)
}

open class TerminalContext: ObservableObject, Identifiable, Equatable {
    public var id: UUID = .init()

    public var navigationTitle: String {
        switch remoteType {
        case .machine: return machine.shortDescription(withComment: false)
        case .command: return command?.command ?? "Unknown Command"
        }
    }

    public var firstConnect = true
    @Published public var destroyedSession = false {
        didSet {
            if destroyedSession {
                shell.destroyPermanently()
            }
        }
    }

    @Published public var navigationSubtitle: String = ""

    private var title: String = "" {
        didSet {
            onMainThread {
                self.navigationSubtitle = self.title
            }
        }
    }

    public enum RemoteType {
        case machine
        case command
    }

    public let remoteType: RemoteType

    public let machine: RDMachine
    public let command: SSHCommandReader?
    public var shell: NSRemoteShell = .init()

    /// The renderer this session writes output to and takes input from.
    public let surface: TerminalSessionSurface

    // MARK: - SHELL CONTEXT

    public var closed: Bool { !continueDecision }

    @Published public var interfaceToken: UUID = .init()
    @Published public var interfaceDisabled: Bool = false

    public static let defaultTerminalSize = CGSize(width: 80, height: 40)

    // The parser thread writes terminalSize and the shell IO thread reads
    // it; main and the bootstrap thread write continueDecision and the IO
    // thread reads it. One lock covers both, as bufferAccessLock does
    // _dataBuffer. Side effects run outside the critical section.
    private let stateAccessLock = NSLock()
    private var _terminalSize: CGSize = defaultTerminalSize
    private var _continueDecision: Bool = true

    public var terminalSize: CGSize {
        get {
            stateAccessLock.lock()
            defer { stateAccessLock.unlock() }
            return _terminalSize
        }
        set {
            stateAccessLock.lock()
            _terminalSize = newValue
            stateAccessLock.unlock()
            shell.explicitRequestStatusPickup()
        }
    }

    private var _dataBuffer: String = ""
    private var bufferAccessLock = NSLock()

    public func getBuffer() -> String {
        bufferAccessLock.lock()
        defer { bufferAccessLock.unlock() }
        let copy = _dataBuffer
        _dataBuffer = ""
        return copy
    }

    public func insertBuffer(_ str: String) {
        bufferAccessLock.lock()
        defer { bufferAccessLock.unlock() }
        guard !closed else { return }
        _dataBuffer += str
        Self.queue.async { [weak self] in
            self?.shell.explicitRequestStatusPickup()
        }
    }

    public var continueDecision: Bool {
        get {
            stateAccessLock.lock()
            defer { stateAccessLock.unlock() }
            return _continueDecision
        }
        set {
            stateAccessLock.lock()
            _continueDecision = newValue
            stateAccessLock.unlock()
            onMainThread {
                self.interfaceDisabled = !self.continueDecision
            }
        }
    }

    // MARK: SHELL CONTEXT -

    private static let queue = DispatchQueue(
        label: "me.mizorewww.terminal",
        attributes: .concurrent
    )

    public init(machine: RDMachine, surface: TerminalSessionSurface) {
        self.machine = machine
        command = nil
        remoteType = .machine
        title = machine.name
        self.surface = surface
        Self.queue.async {
            self.processBootstrap()
        }
    }

    public init(command: SSHCommandReader, surface: TerminalSessionSurface) {
        machine = command.machine
        self.command = command
        title = command.command
        remoteType = .command
        self.surface = surface
        Self.queue.async {
            self.processBootstrap()
        }
    }

    public func setupShellData() {
        // Called on the session's worker queue; reads the worker snapshot.
        shell.applyConnection(for: machine, timeout: CatusshStore.shared.workerTimeoutNumber)
    }

    public static func == (lhs: TerminalContext, rhs: TerminalContext) -> Bool {
        lhs.id == rhs.id
    }

    public func putInformation(_ str: String) {
        surface.write(str + "\r\n")
    }

    public func processBootstrap() {
        defer {
            onMainThread { self.processShutdown(exitFromShell: true) }
        }

        onMainThread {
            guard self.firstConnect else { return }
            self.firstConnect = false
            guard CatusshStore.shared.openInterfaceAutomatically else { return }
            TerminalInterface.uiHandler.autoOpenInterface(self)
        }

        setupShellData()
        // A reconnect starts clean: nothing typed for the old session.
        discardPendingInput()

        debugPrint("\(self) \(#function) \(machine.id)")
        putInformation("[*] Creating Connection")
        continueDecision = true

        surface.setupBellChain {
            debugPrint("terminal bell")
        }
        surface.setupBufferChain { [weak self] buffer in
            self?.insertBuffer(buffer)
        }
        surface.setupTitleChain { [weak self] str in
            self?.title = str
        }
        surface.setupSizeChain { [weak self] size in
            self?.terminalSize = size
        }

        // A UU Remote device has a shell of its own, reached through UU.
        if machine.isUURemoteDevice {
            runUURemoteTerminal()
            return
        }

        let identity: RDIdentity?
        if machine.associatedIdentity != nil {
            guard let resolved = CatusshStore.shared.workerAssociatedIdentity(for: machine) else {
                putInformation("Malformed machine or identity data")
                return
            }
            identity = resolved
        } else {
            identity = nil
        }

        let result = shell.connectAndAuthenticate(
            identity: identity,
            autoIdentities: CatusshStore.shared.workerIdentitiesForAutoAuth
        ) { [self] hintText in
            putInformation(hintText)
        }
        switch result {
        case .success:
            break
        case .connectFailed:
            if let refusal = shell.connectFailureReason {
                putInformation(refusal.replacingOccurrences(of: "\n", with: "\r\n"))
            } else {
                putInformation("Unable to connect for \(machine.remoteAddress):\(machine.remotePort)")
            }
            return
        case .authenticateFailed:
            putInformation("Failed to authenticate connection")
            putInformation("Did you forget to add identity or enable auto authentication?")
            return
        }

        onMainThread {
            guard self.remoteType == .machine else {
                return
            }
            var read = CatusshStore.shared.machineGroup[self.machine.id]
            if read.isNotPlaceholder() {
                read.lastBanner = self.shell.remoteBanner ?? "No Banner"
                CatusshStore.shared.machineGroup[self.machine.id] = read
            }
        }

        shell.begin(withTerminalType: "xterm") {
            debugPrint("channel open")
        } withTerminalSize: { [weak self] in
            var size = self?.terminalSize ?? TerminalContext.defaultTerminalSize
            if size.width < 8 || size.height < 8 {
                // something went wrong
                size = TerminalContext.defaultTerminalSize
            }
            return size
        } withWriteDataBuffer: { [weak self] in
            self?.getBuffer() ?? ""
        } withOutputDataBuffer: { [weak self] output in
            // The main queue is FIFO, so writes stay ordered without
            // blocking the shell IO thread on the UI run loop.
            onMainThread {
                self?.surface.write(output)
            }
        } withContinuationHandler: { [weak self] in
            self?.continueDecision ?? false
        }

        // leave loop
        debugPrint("\(self) \(#function) defer \(machine.id)")
    }

    /// Terminal modes a full-screen program may have left on: the alternate
    /// screen, mouse and focus reports, bracketed paste, kitty keyboard
    /// flags, modifyOtherKeys, application keys, a hidden cursor. A program
    /// that exits turns them off itself; one whose connection drops cannot,
    /// and every mouse move and key would then arrive as escape sequences.
    /// Not a full reset (ESC c), which would also wipe the screen.
    static let modeReset = [
        "\u{1B}[=0;1u", // kitty keyboard flags off, on the alternate screen
        "\u{1B}[?1049l", // back to the main screen
        "\u{1B}[=0;1u", // and off there too
        "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1016l",
        "\u{1B}[?1004l\u{1B}[?2004l\u{1B}[?2026l",
        "\u{1B}[>4;0m", // modifyOtherKeys off
        "\u{1B}[?1l\u{1B}>", // normal cursor keys and keypad
        "\u{1B}[?25h\u{1B}[0m",
    ].joined()

    /// Drops what was typed and not yet sent, so it never reaches the next
    /// session.
    func discardPendingInput() {
        bufferAccessLock.lock()
        _dataBuffer = ""
        bufferAccessLock.unlock()
    }

    public func processShutdown(exitFromShell: Bool = false) {
        surface.write(Self.modeReset)
        discardPendingInput()
        if exitFromShell {
            putInformation("")
            putInformation("[*] Connection Closed")
        }
        if let lastError = shell.getLastError() {
            putInformation("[i] Last Error Provided By Backend")
            putInformation("    " + lastError)
        }
        continueDecision = false
        let shell = shell
        Self.queue.async { [weak shell] in
            shell?.requestDisconnectAndWait()
        }
    }
}
