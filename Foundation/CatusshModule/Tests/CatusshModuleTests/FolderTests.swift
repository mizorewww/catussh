//
//  FolderTests.swift
//  CatusshModuleTests
//

@testable import CatusshModule
import XCTest

@MainActor
final class FolderTests: XCTestCase {
    private var savedMachines = RDMachineGroup()
    private var savedFolders = RDFolderGroup()
    private var store: CatusshStore { .shared }

    override func setUp() async throws {
        savedMachines = store.machineGroup
        savedFolders = store.folderGroup
        store.machineGroup = RDMachineGroup()
        store.folderGroup = RDFolderGroup()
    }

    override func tearDown() async throws {
        store.machineGroup = savedMachines
        store.folderGroup = savedFolders
    }

    private func server(_ name: String, folder: String = "") -> RDMachine {
        let machine = RDMachine(remoteAddress: "\(name).example", remotePort: "22", name: name, group: folder)
        store.machineGroup.insert(machine)
        return machine
    }

    func testNamesOnServersAreFoldersAndEmptyFoldersStay() {
        _ = server("a", folder: "prod")
        store.createFolder(named: "empty")
        XCTAssertEqual(store.folders.map(\.name), ["empty", "prod"])
    }

    func testNewFolderNamesAreUnique() {
        store.createFolder(named: "lab")
        XCTAssertEqual(store.createFolder(named: "lab").name, "lab 2")
        XCTAssertEqual(store.createFolder(named: "  ").name, "New Folder")
    }

    func testRenameMovesServersAndRefusesTakenNames() {
        let a = server("a", folder: "prod")
        _ = server("b", folder: "lab")
        XCTAssertFalse(store.renameFolder("prod", to: "lab"))
        XCTAssertTrue(store.renameFolder("prod", to: "production"))
        XCTAssertEqual(store.machineGroup[a.id].group, "production")
        XCTAssertNil(store.folder(named: "prod"))
    }

    func testDeletingALocalFolderKeepsItsServers() {
        let a = server("a", folder: "prod")
        store.deleteFolder("prod")
        XCTAssertEqual(store.machineGroup[a.id].group, "")
        XCTAssertTrue(store.folders.isEmpty)
    }

    func testDeletingALinkedFolderRemovesOnlyPulledServers() {
        let folder = store.createFolder(named: "UU Remote", source: .uuRemote(userID: "u1"))
        let handMade = server("a", folder: folder.name)
        var device = UUDeviceInfo()
        device.deviceID = "d1"
        device.platform = 4
        let pulled = UURemoteFolderSync.makeMachine(for: device, folder: folder.name)
        store.machineGroup.insert(pulled)
        store.deleteFolder(folder.name)
        XCTAssertFalse(store.machineGroup[pulled.id].isNotPlaceholder())
        XCTAssertEqual(store.machineGroup[handMade.id].group, "")
    }

    func testFolderGroupRoundTrips() throws {
        let group = RDFolderGroup(folders: [RDFolder(name: "a"), RDFolder(name: "b", source: .uuRemote(userID: "42"))])
        let data = try PropertyListEncoder().encode(group)
        XCTAssertEqual(try PropertyListDecoder().decode(RDFolderGroup.self, from: data), group)
    }
}
