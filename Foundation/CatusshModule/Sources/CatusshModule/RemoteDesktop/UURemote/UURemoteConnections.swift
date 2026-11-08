//
//  UURemoteConnections.swift
//  CatusshModule
//
//  UU Remote as a way to reach a device, as Cloudflare Access is for SSH: one
//  connection per device (room, signaling, control, WebRTC data channels)
//  carries that device's terminals, shared by every terminal tab on it and
//  closed a little after the last one. The desktop keeps a connection of its own,
//  which streams the screen.
//

import Foundation
import os

@MainActor
public final class UURemoteConnections {
    public static let shared = UURemoteConnections()

    private struct Entry {
        let driver: UURemoteDriver
        /// Not shown anywhere: it only collects the connection's phase.
        let session: RemoteDesktopSession
        var users: Int
    }

    private var entries: [String: Entry] = [:]
    private nonisolated static let log = Logger(subsystem: "me.mizorewww.rayon", category: "uu-connections")

    private init() {}

    /// The device's terminal connection, ready for terminals: made and
    /// connected if there is none. Pair with `release(_:driver:)`.
    public func acquire(for machine: RDMachine, timeout: TimeInterval = 30) async throws -> UURemoteDriver {
        let deviceID = machine.uuDeviceID
        if var entry = entries[deviceID], !entry.driver.isClosed {
            entry.users += 1
            entries[deviceID] = entry
            do {
                try await waitUntilReady(entry, timeout: timeout)
            } catch {
                release(machine, driver: entry.driver)
                throw error
            }
            return entry.driver
        }
        let session = RemoteDesktopSession(machine: machine, protocolType: .uuRemote)
        let driver = UURemoteDriver(session: session)
        driver.purpose = .terminal
        let entry = Entry(driver: driver, session: session, users: 1)
        entries[deviceID] = entry
        driver.start(session: session)
        do {
            try await waitUntilReady(entry, timeout: timeout)
        } catch {
            release(machine, driver: driver)
            throw error
        }
        return driver
    }

    /// One user fewer of `driver`; the connection closes a few seconds
    /// after the last: what the last one sent (closing or detaching its
    /// session) goes out first, and a terminal opened meanwhile (from the
    /// session list, or the tab replacing a closed one) takes it over. A
    /// driver the device's entry no longer holds (it dropped and was
    /// replaced) leaves the new one alone.
    public func release(_ machine: RDMachine, driver: UURemoteDriver) {
        let deviceID = machine.uuDeviceID
        guard var entry = entries[deviceID] else { return }
        guard entry.driver === driver else {
            driver.stop()
            return
        }
        entry.users -= 1
        if entry.users > 0 {
            entries[deviceID] = entry
            return
        }
        entry.users = 0
        entries[deviceID] = entry
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.linger * 1_000_000_000))
            guard let self, let current = self.entries[deviceID], current.driver === driver, current.users == 0 else { return }
            self.entries.removeValue(forKey: deviceID)
            driver.stop()
        }
    }

    static let linger: TimeInterval = 3

    private func waitUntilReady(_ entry: Entry, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !entry.driver.isReady {
            if case let .failed(reason) = entry.session.phase {
                throw RemoteDesktopFailure(reason)
            }
            if entry.driver.isClosed {
                throw RemoteDesktopFailure("The UU Remote connection closed.")
            }
            if Date() > deadline {
                throw RemoteDesktopFailure("UU Remote did not connect in \(Int(timeout)) seconds. Is the device online?")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The device's terminal sessions, most recently used first.
    public func sessions(for machine: RDMachine) async throws -> [UUTerminalSession] {
        let driver = try await acquire(for: machine)
        defer { release(machine, driver: driver) }
        guard let sessions = await driver.listTerminalSessions() else {
            throw RemoteDesktopFailure("\(machine.name) did not list its terminal sessions.")
        }
        return sessions
    }

    /// Ends a session no terminal here is attached to.
    public func endSession(_ id: UInt32, on machine: RDMachine) async throws {
        let driver = try await acquire(for: machine)
        defer { release(machine, driver: driver) }
        driver.closeTerminal(id)
    }

    /// A port-mapped stream to a service on the device (its sshd, for SSH,
    /// SFTP and the rest), on the device's connection, which stays while the
    /// stream is open. Blocks the calling thread, which is never the main one.
    public nonisolated static func openStream(
        to machine: RDMachine,
        host: String,
        port: UInt16,
        timeout: TimeInterval
    ) -> Result<Int32, UURemotePortMappingTunnel.Failure> {
        typealias Failure = UURemotePortMappingTunnel.Failure
        guard !Thread.isMainThread else { return .failure(Failure("UU Remote streams are not opened on the main thread.")) }
        let acquired = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var lease: Result<UURemoteDriver, Error> = .failure(Failure("UU Remote did not connect in time."))
        // Joining the device's room takes longer than a TCP connect; the
        // caller's timeout is for the stream.
        let connectTimeout = max(timeout, 30)
        Task { @MainActor in
            do { lease = .success(try await shared.acquire(for: machine, timeout: connectTimeout)) } catch { lease = .failure(error) }
            acquired.signal()
        }
        guard acquired.wait(timeout: .now() + connectTimeout + 5) == .success else {
            return .failure(Failure("UU Remote did not connect in \(Int(connectTimeout)) seconds."))
        }
        let driver: UURemoteDriver
        switch lease {
        case let .success(value): driver = value
        case let .failure(error):
            log.error("no connection to \(machine.name, privacy: .public) for a stream: \(error.localizedDescription, privacy: .public)")
            return .failure(Failure(error.localizedDescription))
        }
        let release: @Sendable () -> Void = {
            Task { @MainActor in shared.release(machine, driver: driver) }
        }
        let result = driver.openPortMappingStream(targetHost: host, targetPort: port, timeout: timeout, onClose: release)
        switch result {
        case .success:
            log.info("stream to \(host, privacy: .public):\(port) on \(machine.name, privacy: .public) open")
            return result
        case let .failure(failure):
            log.error("stream to \(host, privacy: .public):\(port) on \(machine.name, privacy: .public) failed: \(failure.message, privacy: .public)")
            release()
            // Nothing listens there: on a Mac, Remote Login is off.
            return .failure(Failure("\(machine.name) did not accept a connection to port \(port) through UU Remote (\(failure.message)). Turn on SSH on the device (on a Mac: System Settings › General › Sharing › Remote Login)."))
        }
    }

    /// What the connection is doing now, for a terminal to show while it waits.
    public func status(for machine: RDMachine) -> String {
        entries[machine.uuDeviceID]?.session.statusHint ?? ""
    }
}
