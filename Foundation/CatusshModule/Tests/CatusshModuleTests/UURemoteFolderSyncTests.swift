//
//  UURemoteFolderSyncTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import XCTest

final class UURemoteFolderSyncTests: XCTestCase {
    private func device(_ id: String, _ alias: String, platform: Int = 4) -> UUDeviceInfo {
        var device = UUDeviceInfo()
        device.deviceID = id
        device.alias = alias
        device.platform = platform
        device.status = "CONNECTED"
        return device
    }

    func testDesktopDevicesBecomeServersInTheFolder() {
        var group = RDMachineGroup()
        UURemoteFolderSync.apply(devices: [device("d1", "Mac"), device("p1", "Phone", platform: 2)], folder: "UU", to: &group)
        XCTAssertEqual(group.machines.map(\.name), ["Mac"])
        XCTAssertEqual(group.machines.first?.group, "UU")
        XCTAssertEqual(group.machines.first?.remoteDesktopProtocol, .uuRemote)
    }

    func testRenamedDevicesRenameUntouchedServersOnly() {
        var group = RDMachineGroup()
        UURemoteFolderSync.apply(devices: [device("d1", "Mac"), device("d2", "PC")], folder: "UU", to: &group)
        var named = group.machines.first { $0.uuDeviceID == "d2" }!
        named.name = "Gaming rig"
        group[named.id] = named
        UURemoteFolderSync.apply(devices: [device("d1", "Mac mini"), device("d2", "PC 2")], folder: "UU", to: &group)
        XCTAssertEqual(Set(group.machines.map(\.name)), ["Mac mini", "Gaming rig"])
    }

    func testDevicesLeavingTheAccountLeaveTheFolder() {
        var group = RDMachineGroup()
        UURemoteFolderSync.apply(devices: [device("d1", "Mac"), device("d2", "PC")], folder: "UU", to: &group)
        // One moved out by the user stays wherever it is.
        var moved = group.machines.first { $0.uuDeviceID == "d2" }!
        moved.group = "Home"
        group[moved.id] = moved
        UURemoteFolderSync.apply(devices: [], folder: "UU", to: &group)
        XCTAssertEqual(group.machines.map(\.uuDeviceID), ["d2"])
    }

    func testCatusshItselfIsNotAServer() {
        var group = RDMachineGroup()
        UURemoteFolderSync.apply(devices: [device("me", "catussh", platform: 1), device("d1", "Mac")], folder: "UU", ownDeviceID: "me", to: &group)
        XCTAssertEqual(group.machines.map(\.uuDeviceID), ["d1"])
    }

    /// Servers saved into "UU Remote" before folders were linked become the
    /// folder's, so a device leaving the account takes its server along.
    func testLegacyServersInTheFolderBecomeManaged() {
        var legacy = UURemoteFolderSync.makeMachine(for: device("d1", "Mac"), folder: "UU Remote")
        legacy.attachment[UURemoteFolderSync.managedKey] = nil
        var group = RDMachineGroup()
        group.insert(legacy)
        UURemoteFolderSync.apply(devices: [device("d1", "Mac")], folder: "UU Remote", to: &group)
        UURemoteFolderSync.apply(devices: [], folder: "UU Remote", to: &group)
        XCTAssertTrue(group.machines.isEmpty)
    }

    func testOnlyUUServersAreUUDevices() {
        var ssh = RDMachine(remoteAddress: "10.0.0.2", remotePort: "22", name: "box")
        ssh.remoteDesktopProtocol = .uuRemote
        ssh.uuDeviceID = "d1"
        XCTAssertFalse(ssh.isUURemoteDevice)
        XCTAssertTrue(UURemoteFolderSync.makeMachine(for: device("d1", "Mac"), folder: "UU").isUURemoteDevice)
    }

    /// A sign-in of catussh is no computer: it never becomes a server.
    func testCatusshSignInsAreNotDesktops() {
        var signIn = device("c1", "catussh", platform: 1)
        signIn.versionName = UUConstants.versionName
        var pc = device("d1", "catussh-lab-pc", platform: 1)
        pc.versionName = "4.44.0.3919"
        var group = RDMachineGroup()
        UURemoteFolderSync.apply(devices: [signIn, pc], folder: "UU", to: &group)
        XCTAssertEqual(group.machines.map(\.uuDeviceID), ["d1"])
    }

    func testEveryDeviceGivesADevicesServerTheSameID() {
        var mac = RDMachineGroup(), pad = RDMachineGroup()
        UURemoteFolderSync.apply(devices: [device("d1", "Mac")], folder: "UU", to: &mac)
        UURemoteFolderSync.apply(devices: [device("d1", "Mac")], folder: "UU", to: &pad)
        XCTAssertEqual(mac.machines.map(\.id), pad.machines.map(\.id))
        XCTAssertEqual(mac.machines.first?.id, UURemoteFolderSync.machineID(for: "d1"))
    }

    func testDuplicatesFromOtherDevicesBecomeOneUnderTheSharedID() {
        func old(_ id: String, name: String) -> RDMachine {
            var machine = UURemoteFolderSync.makeMachine(for: device("d1", "Mac"), folder: "UU")
            machine.id = UUID(uuidString: id)!
            machine.name = name
            return machine
        }
        var jump = RDMachine()
        jump.name = "Behind"
        jump.remoteAddress = "10.0.0.2"
        jump.remotePort = "22"
        jump.proxyJumpMachineID = "BBBBBBBB-0000-0000-0000-000000000000"
        var one = RDMachineGroup(), two = RDMachineGroup()
        one.insert(old("BBBBBBBB-0000-0000-0000-000000000000", name: "From iPad"))
        one.insert(old("AAAAAAAA-0000-0000-0000-000000000000", name: "From Mac"))
        one.insert(jump)
        two.insert(old("AAAAAAAA-0000-0000-0000-000000000000", name: "From Mac"))
        two.insert(old("BBBBBBBB-0000-0000-0000-000000000000", name: "From iPad"))

        let replaced = UURemoteFolderSync.collapseDuplicates(in: &one)
        UURemoteFolderSync.collapseDuplicates(in: &two)
        let shared = UURemoteFolderSync.machineID(for: "d1")
        let kept = one.machines.filter { $0.uuDeviceID == "d1" }
        XCTAssertEqual(kept.map(\.id), [shared])
        // Both devices keep the same one: the lowest id.
        XCTAssertEqual(kept.first?.name, "From Mac")
        XCTAssertEqual(two.machines.map(\.name), ["From Mac"])
        XCTAssertEqual(replaced.count, 2)
        XCTAssertEqual(one.machines.first { $0.name == "Behind" }?.proxyJumpMachineID, shared.uuidString)
        // Nothing left to do the second time.
        XCTAssertTrue(UURemoteFolderSync.collapseDuplicates(in: &one).isEmpty)
    }
}
