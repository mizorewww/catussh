//
//  UURemoteRooms.swift
//  CatusshModule
//
//  A device's UU Remote room, joined once and shared. Joining a device's room
//  (`force_join`) takes it over from whoever held it, our own earlier join
//  included, and the host then drops the sessions that came in through the
//  old one: a desktop opened next to a device's terminals cut every terminal
//  off. So every connection to a device (its desktop, the one its terminals
//  share) asks for control over the same room and signaling socket, each as a
//  session of its own (its app_control_id, ice_id and peer, which route the
//  socket's soac to it), and the room is left with the last of them.
//

import Foundation
import os

/// A connection's hold on its device's room: the signaling socket to ask for
/// control over and to send soac on. Give it back with `UURemoteRooms.leave`.
public struct UURemoteRoomLease: Sendable {
    let room: UURemoteRooms.Room
    let listener: UUID
    public let config: UURoomConfig
    public var signal: UURemoteSignalingClient { room.signal }
}

@MainActor
public final class UURemoteRooms {
    public static let shared = UURemoteRooms()

    /// One joined room and its socket; what arrives on the socket goes to
    /// every connection in the room, each keeping only its own.
    final class Room: @unchecked Sendable {
        let key: String
        let signal = UURemoteSignalingClient()
        /// Main actor: the connections holding the room.
        fileprivate var users = 0
        /// Main actor: the join and the socket's connect, once.
        fileprivate var joined: Task<UURoomConfig, Error>?

        private let lock = NSLock()
        private var eventListeners: [UUID: (String, [[String: Any]], [Data]) -> Void] = [:]
        private var soacListeners: [UUID: ([String: Any]) -> Void] = [:]
        private var dropped = false

        init(key: String) { self.key = key }

        /// The socket is gone (or never came up): a new connection joins anew.
        var isDropped: Bool { lock.withLock { dropped } }

        fileprivate func markDropped() { lock.withLock { dropped = true } }

        /// Opens the socket, everything it receives going to the room's
        /// connections.
        fileprivate nonisolated func connect(_ config: UURoomConfig) async throws {
            await signal.setOnSignalEvent { [weak self] event, args, binary in
                self?.dispatchEvent(event, args, binary)
            }
            await signal.setOnSOAC { [weak self] soac in
                self?.dispatchSOAC(soac)
            }
            await signal.setOnStateChange { [weak self] state in
                if case .error = state { self?.markDropped() }
            }
            try await signal.connect(roomConfig: config)
        }

        fileprivate func addListener(
            _ id: UUID,
            onEvent: @escaping (String, [[String: Any]], [Data]) -> Void,
            onSOAC: @escaping ([String: Any]) -> Void
        ) {
            lock.withLock {
                eventListeners[id] = onEvent
                soacListeners[id] = onSOAC
            }
        }

        fileprivate func removeListener(_ id: UUID) {
            lock.withLock {
                eventListeners.removeValue(forKey: id)
                soacListeners.removeValue(forKey: id)
            }
        }

        fileprivate func dispatchEvent(_ event: String, _ args: [[String: Any]], _ binary: [Data]) {
            for listener in lock.withLock({ Array(eventListeners.values) }) { listener(event, args, binary) }
        }

        fileprivate func dispatchSOAC(_ soac: [String: Any]) {
            for listener in lock.withLock({ Array(soacListeners.values) }) { listener(soac) }
        }
    }

    private var rooms: [String: Room] = [:]
    private nonisolated static let log = Logger(subsystem: "me.mizorewww.rayon", category: "uu-rooms")

    private init() {}

    /// The device's room, joined and its socket connected if no connection
    /// holds it yet. `onEvent` and `onSOAC` get everything the socket
    /// receives, for every connection in the room: each filters by its route.
    public func join(
        _ machine: RDMachine,
        deviceID: String,
        onEvent: @escaping (String, [[String: Any]], [Data]) -> Void,
        onSOAC: @escaping ([String: Any]) -> Void
    ) async throws -> UURemoteRoomLease {
        let assistID = machine.uuAssistID
        let assistCode = machine.uuAssistCode
        let key = assistID.isEmpty ? "device|\(deviceID)" : "assist|\(assistID)"
        let room: Room
        if let existing = rooms[key], !existing.isDropped {
            room = existing
        } else {
            room = Room(key: key)
            rooms[key] = room
            room.joined = Task { @MainActor [room] in
                do {
                    let config: UURoomConfig = if !assistID.isEmpty {
                        try await UURemoteAccountStore.shared.apiClient.joinShareByCode(connectID: assistID, code: assistCode)
                    } else {
                        try await UURemoteAccountStore.shared.apiClient.roomJoinByDevice(deviceID, forceJoin: true)
                    }
                    try await room.connect(config)
                    Self.log.info("joined \(key, privacy: .public)")
                    return config
                } catch {
                    room.markDropped()
                    Self.log.error("could not join \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    throw error
                }
            }
        }
        room.users += 1
        let listener = UUID()
        room.addListener(listener, onEvent: onEvent, onSOAC: onSOAC)
        let lease: UURemoteRoomLease
        do {
            guard let joined = room.joined else { throw RemoteDesktopFailure("The UU Remote room was not joined.") }
            lease = try await UURemoteRoomLease(room: room, listener: listener, config: joined.value)
        } catch {
            leave(room: room, listener: listener)
            throw error
        }
        return lease
    }

    /// One connection fewer in the room; the last one leaves it.
    public func leave(_ lease: UURemoteRoomLease) {
        leave(room: lease.room, listener: lease.listener)
    }

    private func leave(room: Room, listener: UUID) {
        room.removeListener(listener)
        room.users -= 1
        guard room.users <= 0 else { return }
        if rooms[room.key] === room { rooms.removeValue(forKey: room.key) }
        let joined = room.joined
        Task {
            _ = try? await joined?.value
            await room.signal.disconnect()
        }
    }
}
