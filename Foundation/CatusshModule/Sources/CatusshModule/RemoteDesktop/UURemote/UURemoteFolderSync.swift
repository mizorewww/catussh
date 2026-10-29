//
//  UURemoteFolderSync.swift
//  CatusshModule
//
//  A UU Remote account's folder follows the account: every desktop device
//  is a server in it, renamed when the device is, and gone when the device
//  leaves the account. Servers the user made or moved out are left alone.
//

import Foundation

public enum UURemoteFolderSync {
    /// Marks a server as pulled from an account, so a refresh may remove it.
    static let managedKey = "remoteDesktop.uu.managed"

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
        machine.attachment[managedKey] = "1"
        return machine
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
                if machine.group == folder { machine.attachment[managedKey] = "1" }
                if machine != before { group[machine.id] = machine }
            } else {
                group.insert(makeMachine(for: device, folder: folder))
            }
        }
        for machine in group.machines
            where machine.group == folder && machine.attachment[managedKey] == "1" && !present.contains(machine.uuDeviceID)
        {
            group.delete(machine.id)
        }
    }
}
