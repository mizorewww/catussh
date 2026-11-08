//
//  SSHFlowLiveTests.swift
//  CatusshModuleTests
//
//  Against a real SSH server; skipped unless SSH_LIVE_HOST is set (and
//  SSH_LIVE_USER, with the key in ~/.ssh/id_ed25519).
//

@testable import CatusshModule
import NSRemoteShell
import XCTest

final class SSHFlowLiveTests: XCTestCase {
    /// Input pasted while the remote floods output and reads none must not
    /// freeze the session: the client has to keep reading while the remote's
    /// input window is full, or both sides wait on each other for good.
    func testPastingIntoAFloodingProgramDoesNotDeadlock() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["SSH_LIVE_HOST"], !host.isEmpty,
              let user = environment["SSH_LIVE_USER"], !user.isEmpty
        else {
            throw XCTSkip("Set SSH_LIVE_HOST and SSH_LIVE_USER to run the live SSH flow test")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let privateKey = try String(contentsOf: home.appendingPathComponent(".ssh/id_ed25519"), encoding: .utf8)
        let publicKey = try String(contentsOf: home.appendingPathComponent(".ssh/id_ed25519.pub"), encoding: .utf8)

        let shell = NSRemoteShell.configured(host: host, port: "22", timeout: 10)
        shell.requestConnectAndWait()
        shell.authenticate(with: user, andPublicKey: publicKey, andPrivateKey: privateKey, andPassword: nil)
        XCTAssertTrue(shell.isAuthenticated)

        // The remote ignores its input while it writes 20 MB, with 4 MB
        // pasted meanwhile; then it reads what arrived and says it is done.
        let pasted = String(repeating: "x", count: 4_000_000)
        let state = FlowState(inputs: [
            // Then whatever input arrived is read until 3 s pass without
            // any (a full tty drops some; that is the tty, not the client).
            "stty raw -echo; echo READY-$((1+1)); yes | head -c 20000000; perl -e '$SIG{ALRM}=sub{exit}; alarm 3; while (sysread(STDIN, $b, 65536)) { alarm 3 }'; stty sane; echo; echo DONE-$((40+2))\n",
            pasted,
        ])
        let finished = expectation(description: "the remote read everything and finished")
        state.onDone = { finished.fulfill() }
        DispatchQueue.global().async {
            shell.begin(withTerminalType: "xterm-256color") {
            } withTerminalSize: {
                CGSize(width: 120, height: 40)
            } withWriteDataBuffer: {
                state.nextInput()
            } withOutputDataBuffer: { output in
                state.received(output)
            } withContinuationHandler: {
                !state.isDone
            }
        }
        wait(for: [finished], timeout: 120)
        print("SSH_LIVE received \(state.byteCount) bytes, ready \(state.isReady), inputs left \(state.inputsLeft), last: \(state.lastOutput.debugDescription)")
        shell.requestDisconnectAndWait()
    }
}

/// What the flow test sends and has seen, from the shell's loop thread.
private final class FlowState: @unchecked Sendable {
    private let lock = NSLock()
    private var inputs: [String]
    private var tail = ""
    private var bytes = 0
    private var done = false
    var onDone: (() -> Void)?

    init(inputs: [String]) { self.inputs = inputs }

    var isDone: Bool { lock.withLock { done } }
    var byteCount: Int { lock.withLock { bytes } }
    var isReady: Bool { lock.withLock { ready } }
    var inputsLeft: Int { lock.withLock { inputs.count } }
    var lastOutput: String { lock.withLock { String(last.suffix(300)) } }
    private var last = ""

    /// The command at once; the paste once the remote is in raw mode, so
    /// the tty's line buffer does not drop any of it.
    func nextInput() -> String {
        lock.withLock {
            guard !inputs.isEmpty, inputs.count == 2 || ready else { return "" }
            return inputs.removeFirst()
        }
    }
    private var ready = false

    func received(_ output: String) {
        let finished: Bool = lock.withLock {
            bytes += output.utf8.count
            last = String((last + output).suffix(600))
            // Checked before trimming: a chunk may carry the prompt after it.
            let window = tail + output
            tail = String(window.suffix(64))
            if window.contains("READY-2") { ready = true }
            guard !done, window.contains("DONE-42") else { return false }
            done = true
            return true
        }
        if finished { onDone?() }
    }
}

