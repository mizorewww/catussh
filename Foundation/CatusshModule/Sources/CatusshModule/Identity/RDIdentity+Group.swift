//
//  RDIdentity+Group.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/9.
//

import Foundation

public struct RDIdentityGroup: Codable, Identifiable, Equatable, Sendable, RDGroup {
    public var id = UUID()

    public private(set) var identities: [RDIdentity] = []

    public var items: [RDIdentity] {
        get { identities }
        set { identities = newValue }
    }

    public init(id: UUID = UUID(), identities: [RDIdentity] = []) {
        self.id = id
        self.identities = identities
    }

    public static func accepts(_ item: RDIdentity) -> Bool {
        !item.username.isEmpty
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identities == rhs.identities
    }
}
