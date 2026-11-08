//
//  RDGroup.swift
//  CatusshModule
//

import Foundation

/// An element of a store group: identifiable, codable, and with an empty
/// init for the placeholder a lookup returns when the id is unknown.
public protocol RDGroupItem: Identifiable, Codable {
    init()
}

/// The shared behavior of the store groups (machines, identities,
/// snippets, port forwards).
public protocol RDGroup {
    associatedtype Item: RDGroupItem

    /// The group's elements; a shell forwards this to its stored array.
    var items: [Item] { get set }

    /// What insert keeps: each group refuses its own placeholder.
    static func accepts(_ item: Item) -> Bool
}

public extension RDGroup {
    var count: Int { items.count }

    /// Safe optional lookup by ID without allocating a placeholder.
    func find(_ id: Item.ID) -> Item? {
        items.first(where: { $0.id == id })
    }

    mutating func insert(_ value: Item) {
        guard Self.accepts(value) else { return }
        if let index = items.firstIndex(where: { $0.id == value.id }) {
            items[index] = value
        } else {
            items.append(value)
        }
    }

    subscript(_ id: Item.ID) -> Item {
        get {
            items.first(where: { $0.id == id }) ?? .init()
        }

        set(newValue) {
            if let index = items.firstIndex(where: { $0.id == id }) {
                if Self.accepts(newValue) {
                    items[index] = newValue
                } else {
                    items.remove(at: index)
                }
            } else if Self.accepts(newValue) {
                items.append(newValue)
            }
        }
    }

    mutating func delete(_ value: Item.ID) {
        if let index = items.firstIndex(where: { $0.id == value }) {
            items.remove(at: index)
        }
    }
}

/// A group item carrying a `group` tag; groups of such items expose
/// sorted sections.
public protocol RDGroupSectionedItem {
    var group: String { get }
}

public extension RDGroup where Item: RDGroupSectionedItem {
    var sections: [String] {
        [String](Set<String>(
            items.map(\.group)
        )).sorted()
    }

    subscript(section: String) -> [Item] {
        items.filter { $0.group == section }
    }
}
