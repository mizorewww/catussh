//
//  SyncedSettings.swift
//  CatusshModule
//
//  The settings that go with the user from device to device, each under a
//  short name, read from and written to where the app keeps it.
//
//  Left on each device: what is about the device or what happened on it (the
//  recent servers, when a server was last used, window and sidebar state,
//  which servers sit in the Mac's menu bar, the license agreement, logging),
//  sync's own state, and the UU Remote sign-in, which is a session of this
//  device with UU's servers rather than a setting: a copy on another device
//  would share one login between them. Each device signs in on its own.
//

import CatusshTerminal
import Foundation

@MainActor
enum SyncedSettings {
    struct Setting {
        let name: String
        let read: @MainActor () -> SyncSetting?
        let write: @MainActor (SyncSetting?) -> Void
    }

    /// Terminal settings are named "terminal.<Ghostty name>".
    private static let terminalPrefix = "terminal."

    static let all: [Setting] = [
        int("timeout", \.timeout, in: 2 ... 30),
        int("monitorInterval", \.monitorInterval, in: 1 ... 3600),
        int("terminalFontSize", \.terminalFontSize, in: 4 ... 128),
        int("maxRecentRecordCount", \.maxRecentRecordCount, in: 1 ... 50),
        bool("openInterfaceAutomatically", \.openInterfaceAutomatically),
        bool("saveTemporarySession", \.saveTemporarySession),
        bool("storeRecent", \.storeRecent),
        bool("reducedViewEffects", \.reducedViewEffects),
        bool("disableConformation", \.disableConformation),
        bool("terminalCopyOnSelect", \.terminalCopyOnSelect),
        Setting(
            name: "machineRedacted",
            read: { .int(CatusshStore.shared.machineRedacted.rawValue) },
            write: { value in
                guard case let .int(raw) = value, let level = RDMachine.RedactedLevel(rawValue: raw),
                      CatusshStore.shared.machineRedacted != level
                else { return }
                CatusshStore.shared.machineRedacted = level
            }
        ),
        defaults("appearance", "me.mizorewww.rayon.appearance", as: String.self),
        defaults("editor.wrapsLines", "me.mizorewww.rayon.editor.wrapsLines", as: Bool.self),
        defaults("terminfo.install", "me.mizorewww.rayon.terminfo.install", as: Bool.self),
    ]

    /// Every setting this device has, by name.
    static func snapshot() -> [String: SyncSetting] {
        var result: [String: SyncSetting] = [:]
        for setting in all {
            if let value = setting.read() { result[setting.name] = value }
        }
        for (key, values) in TerminalConfigurationSync.overrides {
            result[terminalPrefix + key] = .strings(values)
        }
        return result
    }

    /// Makes the changes from another device; a removed setting goes back to
    /// its default.
    static func apply(_ changes: [SyncKeyedChange<SyncSetting>]) {
        guard !changes.isEmpty else { return }
        let byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var terminal: [String: [String]?] = [:]
        for change in changes {
            let name: String, value: SyncSetting?
            switch change {
            case let .put(key, setting): (name, value) = (key, setting)
            case let .remove(key): (name, value) = (key, nil)
            }
            if name.hasPrefix(terminalPrefix) {
                let key = String(name.dropFirst(terminalPrefix.count))
                if case let .strings(values) = value {
                    terminal[key] = .some(values)
                } else {
                    terminal[key] = .some(nil)
                }
            } else {
                // A setting this version does not have is passed on, not used.
                byName[name]?.write(value)
            }
        }
        TerminalConfigurationSync.adopt(terminal)
    }

    private static func int(
        _ name: String, _ path: ReferenceWritableKeyPath<CatusshStore, Int>, in range: ClosedRange<Int>
    ) -> Setting {
        Setting(
            name: name,
            read: { .int(CatusshStore.shared[keyPath: path]) },
            write: { value in
                guard case let .int(number) = value, range.contains(number),
                      CatusshStore.shared[keyPath: path] != number
                else { return }
                CatusshStore.shared[keyPath: path] = number
            }
        )
    }

    private static func bool(_ name: String, _ path: ReferenceWritableKeyPath<CatusshStore, Bool>) -> Setting {
        Setting(
            name: name,
            read: { .bool(CatusshStore.shared[keyPath: path]) },
            write: { value in
                guard case let .bool(flag) = value, CatusshStore.shared[keyPath: path] != flag else { return }
                CatusshStore.shared[keyPath: path] = flag
            }
        )
    }

    /// A setting kept in the user defaults only (by `@AppStorage`, say); it
    /// is there once it was changed, and its default otherwise.
    private static func defaults<Value>(_ name: String, _ key: String, as _: Value.Type) -> Setting {
        Setting(
            name: name,
            read: {
                switch UserDefaults.standard.object(forKey: key) {
                case let value as String where Value.self == String.self: return .string(value)
                case let value as NSNumber where Value.self == Bool.self: return .bool(value.boolValue)
                default: return nil
                }
            },
            write: { value in
                let defaults = UserDefaults.standard
                switch value {
                case let .string(text) where Value.self == String.self:
                    if defaults.string(forKey: key) != text { defaults.set(text, forKey: key) }
                case let .bool(flag) where Value.self == Bool.self:
                    if defaults.object(forKey: key) as? Bool != flag { defaults.set(flag, forKey: key) }
                case nil:
                    if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
                default:
                    break
                }
            }
        )
    }
}
