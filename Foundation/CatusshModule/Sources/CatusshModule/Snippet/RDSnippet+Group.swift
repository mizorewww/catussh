//
//  RDSnippet+Group.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/10.
//

import Foundation

public struct RDSnippetGroup: Codable, Identifiable, Equatable, Sendable, RDGroup {
    public var id = UUID()

    public private(set) var snippets: [RDSnippet] = []

    public var items: [RDSnippet] {
        get { snippets }
        set { snippets = newValue }
    }

    public init(id: UUID = UUID(), snippets: [RDSnippet] = []) {
        self.id = id
        self.snippets = snippets
    }

    public static func accepts(_ item: RDSnippet) -> Bool {
        !item.name.isEmpty
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snippets == rhs.snippets
    }
}
