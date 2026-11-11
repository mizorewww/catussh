//
//  UURemoteFolderSync.swift
//  CatusshModule
//
//  A UU Remote account's folder follows the account: every desktop device
//  is a server in it, renamed when the device is, and gone when the device
//  leaves the account. Servers the user made or moved out are left alone.
//
//  Every device signed in to the account makes these servers, so each
//  device's server for a UU device has an id worked out from the UU device
//  id: the same everywhere, iCloud sync keeps one of it.
//

import CryptoKit
import Foundation

public enum UURemoteFolderSync {
    /// Marks a server as pulled from an account, so a refresh may remove it.
    static let managedKey = "remoteDesktop.uu.managed"

    /// The id of the server for a UU device, the same on every device.
    public static func machineID(for deviceID: String) -> UUID {
        let hash = Array(SHA256.hash(data: Data("me.mizorewww.rayon.uu-device.\(deviceID)".utf8)))
        var bytes = Array(hash.prefix(16))
        // A name-based UUID (version 5 layout, RFC 4122 variant).
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// A server for a device, in `folder`.
    public static func makeMachine(for device: UUDeviceInfo, folder: String) -> RDMachine {
        var machine = RDMachine(
            remoteAddress: device.deviceID,
            remotePort: "22",
            name: device.alias.isEmpty ? device.deviceID : device.alias,
            group: folder,
            comment: "\(UUDeviceInfo.platformName(device.platform)) device"
        )
        machine.remoteDesktopProtocol = .uuRemote
        machine.uuDeviceID = device.deviceID
        machine.uuDeviceAlias = device.alias
        machine.transport = .uuRemote
        machine.uuManaged = true
        machine.id = machineID(for: device.deviceID)
        return machine
    }

    /// Before ids were shared, each device signed in made its own server for
    /// a UU device, and iCloud sync kept them all. The account's servers for
    /// one UU device become one, under the shared id. Every device picks the
    /// same one (the one under the shared id, else the lowest id), so the
    /// servers they delete agree. Returns the ids that were replaced, and by
    /// what, for whatever refers to them.
    @discardableResult
    public static func collapseDuplicates(in group: inout RDMachineGroup) -> [UUID: UUID] {
        var replaced: [UUID: UUID] = [:]
        let managed = Dictionary(grouping: group.machines.filter { $0.uuManaged && !$0.uuDeviceID.isEmpty }, by: \.uuDeviceID)
        for (deviceID, machines) in managed {
            let shared = machineID(for: deviceID)
            guard machines.contains(where: { $0.id != shared }) else { continue }
            var kept = machines.first { $0.id == shared }
                ?? machines.min { $0.id.uuidString < $1.id.uuidString }!
            for machine in machines where machine.id != shared {
                replaced[machine.id] = shared
                group.delete(machine.id)
            }
            kept.id = shared
            group.insert(kept)
        }
        guard !replaced.isEmpty else { return replaced }
        for var machine in group.machines {
            guard let jump = machine.proxyJumpMachineID.flatMap(UUID.init(uuidString:)),
                  let now = replaced[jump]
            else { continue }
            machine.proxyJumpMachineID = now.uuidString
            group[machine.id] = machine
        }
        return replaced
    }

    /// Brings the servers in `folder` up to date with `devices`. `ownDeviceID`
    /// is the device catussh signed in as, which is not a server.
    public static func apply(devices: [UUDeviceInfo], folder: String, ownDeviceID: String = "", to group: inout RDMachineGroup) {
        let desktops = devices.filter { $0.isDesktop && $0.deviceID != ownDeviceID }
        let present = Set(desktops.map(\.deviceID))
        for device in desktops {
            if var machine = group.machines.first(where: { $0.uuDeviceID == device.deviceID }) {
                let before = machine
                // The name follows the device's until the user gives it one.
                let oldAlias = machine.uuDeviceAlias.isEmpty ? device.deviceID : machine.uuDeviceAlias
                if machine.name == oldAlias, !device.alias.isEmpty { machine.name = device.alias }
                machine.uuDeviceAlias = device.alias
                // Saved before folders by "Add to Servers": the folder's now.
                if machine.group == folder { machine.uuManaged = true }
                if machine != before { group[machine.id] = machine }
            } else {
                group.insert(makeMachine(for: device, folder: folder))
            }
        }
        for machine in group.machines
            where machine.group == folder && machine.uuManaged && !present.contains(machine.uuDeviceID)
        {
            group.delete(machine.id)
        }
    }
}

public extension CatusshStore {
    /// Makes the account's servers for one UU device one server (see
    /// `UURemoteFolderSync.collapseDuplicates`); port forwards and recent
    /// servers follow it.
    func collapseUURemoteDuplicates() {
        var group = machineGroup
        let replaced = UURemoteFolderSync.collapseDuplicates(in: &group)
        guard !replaced.isEmpty else { return }
        machineGroup = group

        var forwards = portForwardGroup
        for var forward in forwards.items {
            guard let machine = forward.usingMachine, let now = replaced[machine] else { continue }
            forward.usingMachine = now
            forwards[forward.id] = forward
        }
        portForwardGroup = forwards

        var seen: Set<String> = []
        recentRecord = recentRecord
            .map { record in
                if case let .machine(machine) = record, let now = replaced[machine] { return .machine(machine: now) }
                return record
            }
            .filter { seen.insert($0.id).inserted }
    }
}
