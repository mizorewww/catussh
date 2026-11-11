//
//  SyncDocument.swift
//  CatusshModule
//
//  What is synced, and how two copies are brought together: item by item, the
//  later change wins, and a deletion is a change like any other.
//

import CryptoKit
import Foundation

/// The document kept in iCloud. An entry without a value is a deleted item.
///
/// Kinds added after the first version are missing from what an earlier
/// version stored, and read as empty.
struct SyncDocument: Codable, Sendable {
    struct Entry<Value: Codable & Sendable>: Codable, Sendable {
        var modified: Date
        var value: Value?
    }

    var machines: [String: Entry<RDMachine>] = [:]
    var identities: [String: Entry<RDIdentity>] = [:]
    var snippets: [String: Entry<RDSnippet>] = [:]
    var portForwards: [String: Entry<RDPortForward>] = [:]
    /// By name: servers name their folder, so two devices that made a folder
    /// of the same name made the same folder.
    var folders: [String: Entry<RDFolder>] = [:]
    /// By setting; see `SyncedSettings`.
    var settings: [String: Entry<SyncSetting>] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machines = try container.decodeIfPresent(type(of: machines), forKey: .machines) ?? [:]
        identities = try container.decodeIfPresent(type(of: identities), forKey: .identities) ?? [:]
        snippets = try container.decodeIfPresent(type(of: snippets), forKey: .snippets) ?? [:]
        portForwards = try container.decodeIfPresent(type(of: portForwards), forKey: .portForwards) ?? [:]
        folders = try container.decodeIfPresent(type(of: folders), forKey: .folders) ?? [:]
        settings = try container.decodeIfPresent(type(of: settings), forKey: .settings) ?? [:]
    }
}

/// What this device last knew of each item: enough to tell what has changed
/// here since, and when. Kept on the device, never uploaded.
struct SyncState: Codable, Sendable, Equatable {
    struct Stamp: Codable, Sendable, Equatable {
        /// Nil for an item that was deleted.
        var digest: String?
        var modified: Date
    }

    var machines: [String: Stamp] = [:]
    var identities: [String: Stamp] = [:]
    var snippets: [String: Stamp] = [:]
    var portForwards: [String: Stamp] = [:]
    var folders: [String: Stamp] = [:]
    var settings: [String: Stamp] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        machines = try container.decodeIfPresent(type(of: machines), forKey: .machines) ?? [:]
        identities = try container.decodeIfPresent(type(of: identities), forKey: .identities) ?? [:]
        snippets = try container.decodeIfPresent(type(of: snippets), forKey: .snippets) ?? [:]
        portForwards = try container.decodeIfPresent(type(of: portForwards), forKey: .portForwards) ?? [:]
        folders = try container.decodeIfPresent(type(of: folders), forKey: .folders) ?? [:]
        settings = try container.decodeIfPresent(type(of: settings), forKey: .settings) ?? [:]
    }
}

/// A change to make on this device to an item kept under its id.
enum SyncChange<Value: Sendable>: Sendable {
    case put(Value)
    case remove(UUID)
}

/// A change to make on this device to a value kept under a name (a folder,
/// a setting).
enum SyncKeyedChange<Value: Sendable>: Sendable {
    case put(String, Value)
    case remove(String)
}

/// Something that syncs.
protocol SyncValue: Codable, Sendable {
    /// The value without what every device keeps for itself (when it was last
    /// used here). Two values with the same content are the same value.
    var content: Self { get }
    /// This value as it came from another device, keeping what `local` has of
    /// its own.
    func arriving(over local: Self?) -> Self
}

extension SyncValue {
    var content: Self { self }
    func arriving(over _: Self?) -> Self { self }
}

/// Something that syncs under its id.
protocol SyncItem: SyncValue, Identifiable where ID == UUID {}

extension RDMachine: SyncItem {
    var content: RDMachine {
        var copy = self
        copy.lastConnection = Date(timeIntervalSinceReferenceDate: 0)
        copy.lastBanner = ""
        return copy
    }

    func arriving(over local: RDMachine?) -> RDMachine {
        guard let local else { return self }
        var copy = self
        copy.lastConnection = local.lastConnection
        copy.lastBanner = local.lastBanner
        return copy
    }
}

extension RDIdentity: SyncItem {
    var content: RDIdentity {
        var copy = self
        copy.lastRecentUsed = Date(timeIntervalSinceReferenceDate: 0)
        return copy
    }

    func arriving(over local: RDIdentity?) -> RDIdentity {
        guard let local else { return self }
        var copy = self
        copy.lastRecentUsed = local.lastRecentUsed
        return copy
    }
}

extension RDSnippet: SyncItem {}

extension RDPortForward: SyncItem {}

/// A folder syncs under its name; its id is each device's own.
extension RDFolder: SyncValue {
    var content: RDFolder {
        var copy = self
        copy.id = UUID(uuid: UUID_NULL)
        return copy
    }

    func arriving(over local: RDFolder?) -> RDFolder {
        var copy = self
        copy.id = local?.id ?? UUID()
        return copy
    }
}

/// The value of one setting.
enum SyncSetting: Codable, Sendable, Equatable, SyncValue {
    case bool(Bool)
    case int(Int)
    case string(String)
    case strings([String])
}

enum SyncMerge {
    /// A deletion is remembered this long, so a device that was away learns of
    /// it instead of bringing the item back.
    static let tombstoneLifetime: TimeInterval = 180 * 24 * 3600

    struct Result<Value: SyncValue> {
        /// The document's entries after the merge.
        var entries: [String: SyncDocument.Entry<Value>]
        /// What to change on this device.
        var changes: [SyncKeyedChange<Value>] = []
        /// The entries differ from the remote ones and are to be uploaded.
        var dirty = false

        /// The changes to items kept under their id.
        func itemChanges() -> [SyncChange<Value>] where Value: SyncItem {
            changes.compactMap { change in
                switch change {
                case let .put(_, value): return .put(value)
                case let .remove(id): return UUID(uuidString: id).map { .remove($0) }
                }
            }
        }
    }

    private static let sharedSyncEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let hexLookup = Array("0123456789abcdef".utf8)

    static func digest<Value: SyncValue>(_ value: Value) -> String {
        let data = (try? sharedSyncEncoder.encode(value.content)) ?? Data()
        let hash = SHA256.hash(data: data)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in hash {
            out.append(hexLookup[Int(byte >> 4)])
            out.append(hexLookup[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func reconcile<Value: SyncItem>(
        local: [Value],
        state: inout [String: SyncState.Stamp],
        remote: [String: SyncDocument.Entry<Value>],
        now: Date
    ) -> Result<Value> {
        var items: [String: Value] = [:]
        for value in local { items[value.id.uuidString] = value }
        return reconcile(local: items, state: &state, remote: remote, now: now)
    }

    static func reconcile<Value: SyncValue>(
        local: [String: Value],
        state: inout [String: SyncState.Stamp],
        remote: [String: SyncDocument.Entry<Value>],
        now: Date
    ) -> Result<Value> {
        var items = local

        // What changed here since the last sync: edited or new items, and
        // items that are gone. A change is dated after the one it follows,
        // even if that one came from a device whose clock runs ahead.
        func date(after stamp: SyncState.Stamp?) -> Date {
            guard let stamp else { return now }
            return max(now, stamp.modified.addingTimeInterval(0.001))
        }
        for (id, value) in items {
            let digest = digest(value)
            guard let known = state[id] else {
                // Never synced from here (sync was just turned on): what is
                // stored stands. Only an item the store lacks is new.
                if remote[id] == nil { state[id] = .init(digest: digest, modified: now) }
                continue
            }
            if known.digest != digest {
                state[id] = .init(digest: digest, modified: date(after: known))
            }
        }
        for (id, stamp) in state where stamp.digest != nil && items[id] == nil {
            state[id] = .init(digest: nil, modified: date(after: stamp))
        }

        var result = Result(entries: remote)
        for id in Set(state.keys).union(remote.keys) {
            switch (state[id], remote[id]) {
            case (nil, nil):
                continue
            case let (mine?, nil):
                guard mine.digest != nil else {
                    // Deleted here and not stored: nothing left to say.
                    state[id] = nil
                    continue
                }
                result.entries[id] = .init(modified: mine.modified, value: items[id])
                result.dirty = true
            case let (mine, theirs?):
                let theirDigest = theirs.value.map(digest)
                guard let mine else {
                    adopt(theirs, id, theirDigest, &items, &state, &result)
                    continue
                }
                if theirDigest == mine.digest {
                    // The same content: the stored date stands.
                    state[id]?.modified = theirs.modified
                } else if theirs.modified > mine.modified
                    // Changed at the same instant on two devices: both must
                    // pick the same one.
                    || (theirs.modified == mine.modified && (theirDigest ?? "") > (mine.digest ?? ""))
                {
                    adopt(theirs, id, theirDigest, &items, &state, &result)
                } else {
                    result.entries[id] = .init(modified: mine.modified, value: items[id])
                    result.dirty = true
                }
            }
        }

        let expiry = now.addingTimeInterval(-tombstoneLifetime)
        for (id, entry) in result.entries where entry.value == nil && entry.modified < expiry {
            result.entries[id] = nil
            state[id] = nil
            result.dirty = true
        }
        return result
    }

    private static func adopt<Value: SyncValue>(
        _ theirs: SyncDocument.Entry<Value>,
        _ id: String,
        _ digest: String?,
        _ items: inout [String: Value],
        _ state: inout [String: SyncState.Stamp],
        _ result: inout Result<Value>
    ) {
        if let value = theirs.value {
            let arrived = value.arriving(over: items[id])
            items[id] = arrived
            result.changes.append(.put(id, arrived))
        } else if items[id] != nil {
            items[id] = nil
            result.changes.append(.remove(id))
        }
        state[id] = .init(digest: digest, modified: theirs.modified)
    }
}
