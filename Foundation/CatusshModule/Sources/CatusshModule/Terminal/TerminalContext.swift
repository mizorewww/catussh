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

open class TerminalContext: ObservableObject, Identifiable, Equatable, @unchecked Sendable {
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

    private var _title: String = ""
    private var title: String {
        get {
            stateAccessLock.lock()
            defer { stateAccessLock.unlock() }
            return _title
        }
        set {
            stateAccessLock.lock()
            _title = newValue
            stateAccessLock.unlock()
            onMainThread { [weak self] in
                self?.navigationSubtitle = newValue
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

    /// On a UU Remote device: the host's session this tab shows.
    public var uuSessionID: UInt32?

    /// The renderer this session writes output to and takes input from.
    public let surface: TerminalSessionSurface

    // MARK: - SHELL CONTEXT

    public var closed: Bool { !continueDecision }

    @Published public var interfaceToken: UUID = .init()
    @Published public var interfaceDisabled: Bool = false

    public static let defaultTerminalSize = CGSize(width: 80, height: 40)

    private let stateAccessLock = NSLock()
    private var _terminalSize: CGSize = defaultTerminalSize
    private var _continueDecision: Bool = true
    internal let uuWakeSemaphore = DispatchSemaphore(value: 0)

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
            uuWakeSemaphore.signal()
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
        guard !closed else {
            bufferAccessLock.unlock()
            return
        }
        _dataBuffer += str
        bufferAccessLock.unlock()
        shell.explicitRequestStatusPickup()
        uuWakeSemaphore.signal()
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
            uuWakeSemaphore.signal()
            onMainThread { [weak self] in
                guard let self else { return }
                self.interfaceDisabled = !newValue
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
        _title = machine.name
        self.surface = surface
        Self.queue.async {
            self.processBootstrap()
        }
    }

    public init(command: SSHCommandReader, surface: TerminalSessionSurface) {
        machine = command.machine
        self.command = command
        _title = command.command
        remoteType = .command
        self.surface = surface
        Self.queue.async {
            self.processBootstrap()
        }
    }

    public func setupShellData() {
        shell.applyConnection(for: machine, timeout: CatusshStore.shared.workerTimeoutNumber)
    }

    public static func == (lhs: TerminalContext, rhs: TerminalContext) -> Bool {
        lhs.id == rhs.id
    }

    public func putInformation(_ str: String) {
        if str.isEmpty {
            surface.write("\r\n")
        } else {
            surface.write("\r\n" + str + "\r\n")
        }
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
                let newBanner = self.shell.remoteBanner ?? "No Banner"
                if read.lastBanner != newBanner {
                    read.lastBanner = newBanner
                    CatusshStore.shared.machineGroup[self.machine.id] = read
                }
            }
        }

        let terminalType = prepareTerminalType()
        shell.begin(withTerminalType: terminalType) {
            debugPrint("channel open")
        } withTerminalSize: { [weak self] in
            var size = self?.terminalSize ?? TerminalContext.defaultTerminalSize
            if size.width < 8 || size.height < 8 {
                size = TerminalContext.defaultTerminalSize
            }
            return size
        } withWriteDataBuffer: { [weak self] in
            self?.getBuffer() ?? ""
        } withOutputDataBuffer: { [weak self] output in
            // TerminalOutputBuffer and CatusshTerminalView.write are thread-safe;
            // write directly from the SSH worker thread to avoid flooding the main queue.
            self?.surface.write(output)
        } withContinuationHandler: { [weak self] in
            self?.continueDecision ?? false
        }

        debugPrint("\(self) \(#function) defer \(machine.id)")
    }

    static let modeReset = [
        "\u{1B}[=0;1u",
        "\u{1B}[?1049l",
        "\u{1B}[=0;1u",
        "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1005l\u{1B}[?1006l\u{1B}[?1015l\u{1B}[?1016l",
        "\u{1B}[?1004l\u{1B}[?2004l\u{1B}[?2026l",
        "\u{1B}[>4;0m",
        "\u{1B}[?1l\u{1B}>",
        "\u{1B}[?25h\u{1B}[0m",
    ].joined()

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
