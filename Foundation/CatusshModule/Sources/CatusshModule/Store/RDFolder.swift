//
//  RDFolder.swift
//  CatusshModule
//
//  A folder of servers. Servers name their folder in `group`, as they always
//  have, so saved and synced servers keep their place; the folder itself
//  records what a name alone cannot: that it exists while empty, and where
//  its servers come from (made here, or pulled from a UU Remote account).
//

import Foundation

public struct RDFolder: Codable, Identifiable, Equatable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        /// Servers are added and removed by hand.
        case local
        /// Servers are the desktop devices of the UU Remote account with this
        /// user id, brought up to date on every refresh.
        case uuRemote(userID: String)
    }

    public var id: UUID
    public var name: String
    public var source: Source

    public init(id: UUID = UUID(), name: String, source: Source = .local) {
        self.id = id
        self.name = name
        self.source = source
    }

    /// Whether its servers come from an account rather than from the user.
    public var isLinked: Bool { source != .local }
}

public struct RDFolderGroup: Codable, Equatable, Sendable {
    public var folders: [RDFolder] = []

    public init(folders: [RDFolder] = []) {
        self.folders = folders
    }

    public func folder(named name: String) -> RDFolder? {
        folders.first { $0.name == name }
    }
}
