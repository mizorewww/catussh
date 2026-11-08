//
//  RDMachine+Group.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/8.
//

import Foundation

public struct RDMachineGroup: Codable, Identifiable, Equatable, Sendable, RDGroup {
    public var id = UUID()

    public private(set) var machines: [RDMachine] = []

    public var items: [RDMachine] {
        get { machines }
        set { machines = newValue }
    }

    public init(id: UUID = UUID(), machines: [RDMachine] = []) {
        self.id = id
        self.machines = machines
    }

    public static func accepts(_ item: RDMachine) -> Bool {
        item.isNotPlaceholder()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.machines == rhs.machines
    }
}
