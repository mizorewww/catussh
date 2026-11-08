//
//  RDPortForward+Group.swift
//
//
//  Created by Lakr Aream on 2022/3/10.
//

import Foundation

public struct RDPortForwardGroup: Codable, Identifiable, Equatable, Sendable, RDGroup {
    public var id = UUID()

    public private(set) var forwards: [RDPortForward] = []

    public var items: [RDPortForward] {
        get { forwards }
        set { forwards = newValue }
    }

    public init(id: UUID = UUID(), forwards: [RDPortForward] = []) {
        self.id = id
        self.forwards = forwards
    }

    public static func accepts(_ item: RDPortForward) -> Bool {
        !item.targetHost.isEmpty && item.bindPort > 0 && item.targetPort > 0
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.forwards == rhs.forwards
    }
}
