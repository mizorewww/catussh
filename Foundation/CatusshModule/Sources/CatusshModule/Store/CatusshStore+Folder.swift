//
//  CatusshStore+Folder.swift
//  CatusshModule
//
//  Folder operations. A folder is its name on the servers in it plus its
//  record in `folderGroup`; every operation keeps the two in step.
//

import Foundation

public extension CatusshStore {
    /// Every folder in order: the recorded ones, then names servers carry
    /// that were never recorded (servers saved before folders existed, or
    /// synced from another device), as local folders. The unnamed default
    /// folder is not listed.
    var folders: [RDFolder] {
        var result = folderGroup.folders
        for name in Set(machineGroup.machines.map(\.group)) where !name.isEmpty && folderGroup.folder(named: name) == nil {
            result.append(RDFolder(name: name))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func folder(named name: String) -> RDFolder? {
        folders.first { $0.name == name }
    }

    func machines(inFolder name: String) -> [RDMachine] {
        machineGroup.machines.filter { $0.group == name }
    }

    /// A folder name not yet taken: `base`, else "base 2", "base 3"…
    func availableFolderName(_ base: String) -> String {
        let taken = Set(folders.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// Adds an empty folder and returns it; the name is made unique.
    @discardableResult
    func createFolder(named name: String, source: RDFolder.Source = .local) -> RDFolder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = RDFolder(name: availableFolderName(trimmed.isEmpty ? "New Folder" : trimmed), source: source)
        folderGroup.folders.append(folder)
        return folder
    }

    /// Renames a folder and moves its servers with it. False when the new name
    /// is empty or taken by another folder.
    @discardableResult
    func renameFolder(_ oldName: String, to newName: String) -> Bool {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !oldName.isEmpty else { return false }
        if name == oldName { return true }
        guard folder(named: name) == nil else { return false }
        var group = folderGroup
        if let index = group.folders.firstIndex(where: { $0.name == oldName }) {
            group.folders[index].name = name
        } else {
            group.folders.append(RDFolder(name: name))
        }
        folderGroup = group
        moveServers(machines(inFolder: oldName).map(\.id), toFolder: name)
        return true
    }

    /// Removes a folder. Servers pulled from an account go with it; every
    /// other server in it moves to the default folder. Unlinking the account,
    /// so a refresh does not bring the folder back, is the caller's part.
    func deleteFolder(_ name: String) {
        guard !name.isEmpty else { return }
        folderGroup.folders.removeAll { $0.name == name }
        var group = machineGroup
        for machine in machines(inFolder: name) {
            if machine.attachment[UURemoteFolderSync.managedKey] == "1" {
                group.delete(machine.id)
            } else {
                var moved = machine
                moved.group = ""
                group[machine.id] = moved
            }
        }
        if group != machineGroup { machineGroup = group }
    }

    /// Puts servers in a folder ("" is the default one).
    func moveServers(_ ids: [RDMachine.ID], toFolder name: String) {
        var group = machineGroup
        for id in ids {
            var machine = group[id]
            guard machine.isNotPlaceholder(), machine.group != name else { continue }
            machine.group = name
            group[id] = machine
        }
        if group != machineGroup { machineGroup = group }
    }
}
