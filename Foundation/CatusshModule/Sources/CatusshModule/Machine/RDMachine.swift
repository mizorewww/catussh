//
//  RDMachine.swift
//  catussh
//
//  Created by Lakr Aream on 2022/2/8.
//

import Foundation

public struct RDMachine: Codable, Identifiable, Equatable, Sendable {
    public init(
        id: UUID = UUID(),
        remoteAddress: String = "",
        remotePort: String = "",
        name: String = "",
        group: String = "",
        lastConnection: Date = .init(),
        lastBanner: String = "",
        comment: String = "",
        associatedIdentity: String? = nil,
        attachment: [String: String] = [:],
        fileTransferLoginPath: String = "/",
        transport: Transport = .direct,
        cloudflareServiceTokenID: String = "",
        cloudflareServiceTokenSecret: String = "",
        remoteDesktopProtocol: RemoteDesktopProtocolType = .none,
        vncPort: String = "5900",
        vncPassword: String = "",
        vncUsername: String = "",
        vncShared: Bool = true,
        vncOverSSH: Bool = false,
        uuDeviceID: String = "",
        uuDeviceAlias: String = "",
        uuAnonymousDeviceID: String = "",
        uuAssistID: String = "",
        uuAssistCode: String = "",
        uuDisplayID: Int = 0,
        uuFPS: Int = 60,
        uuQuality: Int = 5,
        uuManaged: Bool = false,
        ghosttyTerminfoVersion: String? = nil
    ) {
        self.id = id
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.name = name
        self.group = group
        self.lastConnection = lastConnection
        self.lastBanner = lastBanner
        self.comment = comment
        self.associatedIdentity = associatedIdentity
        self.attachment = attachment
        self.fileTransferLoginPath = fileTransferLoginPath
        self.transport = transport
        self.cloudflareServiceTokenID = cloudflareServiceTokenID
        self.cloudflareServiceTokenSecret = cloudflareServiceTokenSecret
        self.remoteDesktopProtocol = remoteDesktopProtocol
        self.vncPort = vncPort
        self.vncPassword = vncPassword
        self.vncUsername = vncUsername
        self.vncShared = vncShared
        self.vncOverSSH = vncOverSSH
        self.uuDeviceID = uuDeviceID
        self.uuDeviceAlias = uuDeviceAlias
        self.uuAnonymousDeviceID = uuAnonymousDeviceID
        self.uuAssistID = uuAssistID
        self.uuAssistCode = uuAssistCode
        self.uuDisplayID = uuDisplayID
        self.uuFPS = uuFPS
        self.uuQuality = uuQuality
        self.uuManaged = uuManaged
        self.ghosttyTerminfoVersion = ghosttyTerminfoVersion
    }

    public var id = UUID()

    // generic authenticate field required for ssh
    public var remoteAddress: String
    public var remotePort: String

    // application required
    public var name: String
    public var group: String
    public var lastConnection: Date
    public var lastBanner: String
    public var comment: String
    public var associatedIdentity: String?

    // reserved for custom metadata
    public var attachment: [String: String]

    // strongly-typed connection & feature settings
    public var fileTransferLoginPath: String = "/"
    public var transport: Transport = .direct
    public var cloudflareServiceTokenID: String = ""
    public var cloudflareServiceTokenSecret: String = ""
    public var remoteDesktopProtocol: RemoteDesktopProtocolType = .none
    public var vncPort: String = "5900"
    public var vncPassword: String = ""
    public var vncUsername: String = ""
    public var vncShared: Bool = true
    public var vncOverSSH: Bool = false
    public var uuDeviceID: String = ""
    public var uuDeviceAlias: String = ""
    public var uuAnonymousDeviceID: String = ""
    public var uuAssistID: String = ""
    public var uuAssistCode: String = ""
    public var uuDisplayID: Int = 0
    public var uuFPS: Int = 60
    public var uuQuality: Int = 5
    public var uuManaged: Bool = false
    public var ghosttyTerminfoVersion: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id
        case remoteAddress
        case remotePort
        case name
        case group
        case lastConnection
        case lastBanner
        case comment
        case associatedIdentity
        case attachment
        case fileTransferLoginPath
        case transport
        case cloudflareServiceTokenID
        case cloudflareServiceTokenSecret
        case remoteDesktopProtocol
        case vncPort
        case vncPassword
        case vncUsername
        case vncShared
        case vncOverSSH
        case uuDeviceID
        case uuDeviceAlias
        case uuAnonymousDeviceID
        case uuAssistID
        case uuAssistCode
        case uuDisplayID
        case uuFPS
        case uuQuality
        case uuManaged
        case ghosttyTerminfoVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        remoteAddress = try container.decode(String.self, forKey: .remoteAddress)
        remotePort = try container.decode(String.self, forKey: .remotePort)
        name = try container.decode(String.self, forKey: .name)
        group = try container.decode(String.self, forKey: .group)
        lastConnection = try container.decode(Date.self, forKey: .lastConnection)
        lastBanner = try container.decode(String.self, forKey: .lastBanner)
        comment = try container.decode(String.self, forKey: .comment)
        associatedIdentity = try container.decodeIfPresent(String.self, forKey: .associatedIdentity)
        attachment = try container.decodeIfPresent([String: String].self, forKey: .attachment) ?? [:]

        fileTransferLoginPath = try container.decodeIfPresent(String.self, forKey: .fileTransferLoginPath) ?? "/"
        transport = try container.decodeIfPresent(Transport.self, forKey: .transport) ?? .direct
        cloudflareServiceTokenID = try container.decodeIfPresent(String.self, forKey: .cloudflareServiceTokenID) ?? ""
        cloudflareServiceTokenSecret = try container.decodeIfPresent(String.self, forKey: .cloudflareServiceTokenSecret) ?? ""
        remoteDesktopProtocol = try container.decodeIfPresent(RemoteDesktopProtocolType.self, forKey: .remoteDesktopProtocol) ?? .none
        vncPort = try container.decodeIfPresent(String.self, forKey: .vncPort) ?? "5900"
        vncPassword = try container.decodeIfPresent(String.self, forKey: .vncPassword) ?? ""
        vncUsername = try container.decodeIfPresent(String.self, forKey: .vncUsername) ?? ""
        vncShared = try container.decodeIfPresent(Bool.self, forKey: .vncShared) ?? true
        vncOverSSH = try container.decodeIfPresent(Bool.self, forKey: .vncOverSSH) ?? false
        uuDeviceID = try container.decodeIfPresent(String.self, forKey: .uuDeviceID) ?? ""
        uuDeviceAlias = try container.decodeIfPresent(String.self, forKey: .uuDeviceAlias) ?? ""
        uuAnonymousDeviceID = try container.decodeIfPresent(String.self, forKey: .uuAnonymousDeviceID) ?? ""
        uuAssistID = try container.decodeIfPresent(String.self, forKey: .uuAssistID) ?? ""
        uuAssistCode = try container.decodeIfPresent(String.self, forKey: .uuAssistCode) ?? ""
        uuDisplayID = try container.decodeIfPresent(Int.self, forKey: .uuDisplayID) ?? 0
        uuFPS = try container.decodeIfPresent(Int.self, forKey: .uuFPS) ?? 60
        uuQuality = try container.decodeIfPresent(Int.self, forKey: .uuQuality) ?? 5
        uuManaged = try container.decodeIfPresent(Bool.self, forKey: .uuManaged) ?? false
        ghosttyTerminfoVersion = try container.decodeIfPresent(String.self, forKey: .ghosttyTerminfoVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(remoteAddress, forKey: .remoteAddress)
        try container.encode(remotePort, forKey: .remotePort)
        try container.encode(name, forKey: .name)
        try container.encode(group, forKey: .group)
        try container.encode(lastConnection, forKey: .lastConnection)
        try container.encode(lastBanner, forKey: .lastBanner)
        try container.encode(comment, forKey: .comment)
        try container.encodeIfPresent(associatedIdentity, forKey: .associatedIdentity)
        try container.encode(attachment, forKey: .attachment)

        if fileTransferLoginPath != "/" {
            try container.encode(fileTransferLoginPath, forKey: .fileTransferLoginPath)
        }
        if transport != .direct {
            try container.encode(transport, forKey: .transport)
        }
        if !cloudflareServiceTokenID.isEmpty {
            try container.encode(cloudflareServiceTokenID, forKey: .cloudflareServiceTokenID)
        }
        if !cloudflareServiceTokenSecret.isEmpty {
            try container.encode(cloudflareServiceTokenSecret, forKey: .cloudflareServiceTokenSecret)
        }
        if remoteDesktopProtocol != .none {
            try container.encode(remoteDesktopProtocol, forKey: .remoteDesktopProtocol)
        }
        if !vncPort.isEmpty, vncPort != "5900" {
            try container.encode(vncPort, forKey: .vncPort)
        }
        if !vncPassword.isEmpty {
            try container.encode(vncPassword, forKey: .vncPassword)
        }
        if !vncUsername.isEmpty {
            try container.encode(vncUsername, forKey: .vncUsername)
        }
        if !vncShared {
            try container.encode(vncShared, forKey: .vncShared)
        }
        if vncOverSSH {
            try container.encode(vncOverSSH, forKey: .vncOverSSH)
        }
        if !uuDeviceID.isEmpty {
            try container.encode(uuDeviceID, forKey: .uuDeviceID)
        }
        if !uuDeviceAlias.isEmpty {
            try container.encode(uuDeviceAlias, forKey: .uuDeviceAlias)
        }
        if !uuAnonymousDeviceID.isEmpty {
            try container.encode(uuAnonymousDeviceID, forKey: .uuAnonymousDeviceID)
        }
        if !uuAssistID.isEmpty {
            try container.encode(uuAssistID, forKey: .uuAssistID)
        }
        if !uuAssistCode.isEmpty {
            try container.encode(uuAssistCode, forKey: .uuAssistCode)
        }
        if uuDisplayID != 0 {
            try container.encode(uuDisplayID, forKey: .uuDisplayID)
        }
        if uuFPS != 60 {
            try container.encode(uuFPS, forKey: .uuFPS)
        }
        if uuQuality != 5 {
            try container.encode(uuQuality, forKey: .uuQuality)
        }
        if uuManaged {
            try container.encode(uuManaged, forKey: .uuManaged)
        }
        try container.encodeIfPresent(ghosttyTerminfoVersion, forKey: .ghosttyTerminfoVersion)
    }

    public func isQualifiedForSearch(text: String) -> Bool {
        let searchText = text.lowercased()
        if remoteAddress.lowercased().contains(searchText) { return true }
        if remotePort.lowercased().contains(searchText) { return true }
        if name.lowercased().contains(searchText) { return true }
        if group.lowercased().contains(searchText) { return true }
        if lastBanner.lowercased().contains(searchText) { return true }
        if comment.lowercased().contains(searchText) { return true }
        return false
    }

    public func shortDescription(withComment: Bool = true) -> String {
        if isUURemoteDevice { return name }
        var build = name + " "
        if let identity = CatusshStore.shared.workerAssociatedIdentity(for: self),
           !identity.username.isEmpty
        {
            build += identity.username + "@"
        }
        build += remoteAddress
        if remotePort != "22" {
            build += " -p " + remotePort
        }
        if withComment, !comment.isEmpty {
            build += " (" + comment + ")"
        }
        return build
    }

    public func isNotPlaceholder() -> Bool {
        !remoteAddress.isEmpty && !remotePort.isEmpty
    }

    public func getCommand(insertLeadingSSH: Bool = true) -> String {
        var build = ""
        let leading = insertLeadingSSH ? "ssh " : ""
        if let oid = CatusshStore.shared.workerAssociatedIdentity(for: self),
           !oid.username.isEmpty
        {
            build = leading + "\(oid.username)@\(remoteAddress)"
        }
        if build.isEmpty {
            build = leading + "\(remoteAddress)"
        }
        if remotePort != "22" {
            build += " -p " + remotePort
        }
        if transport == .cloudflareAccess, insertLeadingSSH {
            build = "ssh " + SSHCommandReader.cloudflareProxyOption + build.dropFirst(3)
        }
        return build
    }
}

extension RDMachine: RDGroupItem, RDGroupSectionedItem {
    public init() { self.init(id: UUID()) }
}
