//
//  UURemoteConnections.swift
//  CatusshModule
//
//  UU Remote as a way to reach a device, as Cloudflare Access is for SSH: one
//  connection per device (room, signaling, control, WebRTC data channels)
//  carries that device's terminals, shared by every terminal tab on it and
//  closed with the last one. The desktop keeps a connection of its own,
//  which streams the screen.
//

import Foundation

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

    private init() {}

    /// The device's terminal connection, ready for terminals: made and
    /// connected if there is none. Pair with `release(_:)`.
    public func acquire(for machine: RDMachine, timeout: TimeInterval = 30) async throws -> UURemoteDriver {
        let deviceID = machine.uuDeviceID
        if var entry = entries[deviceID], !entry.driver.isClosed {
            entry.users += 1
            entries[deviceID] = entry
            try await waitUntilReady(entry, timeout: timeout)
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
            release(machine)
            throw error
        }
        return driver
    }

    /// One user fewer; the connection closes with the last.
    public func release(_ machine: RDMachine) {
        let deviceID = machine.uuDeviceID
        guard var entry = entries[deviceID] else { return }
        entry.users -= 1
        if entry.users > 0 {
            entries[deviceID] = entry
            return
        }
        entries.removeValue(forKey: deviceID)
        entry.driver.stop()
    }

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

    /// What the connection is doing now, for a terminal to show while it waits.
    public func status(for machine: RDMachine) -> String {
        entries[machine.uuDeviceID]?.session.statusHint ?? ""
    }
}
