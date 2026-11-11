//
//  SyncKeychain.swift
//  CatusshModule
//
//  The keys that seal what is in iCloud, kept in iCloud Keychain: the first
//  device makes one, and iCloud Keychain (end-to-end encrypted) brings it to
//  the user's other devices. Each key is its own item, named by its id, so
//  two devices that make one at the same time both keep theirs, and a key
//  made after a reset does not replace one still in use until it is removed.
//
//  The items are in the keychain access group the app is signed with on every
//  platform (Workflow/Scripts: "<team>.me.mizorewww.rayon"); without it the
//  key would stay on the device that made it.
//

import Foundation
import Security

enum SyncKeychain {
    enum Failure: Error {
        /// The app cannot keep items in iCloud Keychain: it is not signed
        /// for a keychain access group, or there is no keychain to keep them in.
        case unavailable(OSStatus)
        /// The keychain is there but did not answer (locked, say).
        case failed(OSStatus)
    }

    private static let service = "me.mizorewww.rayon.sync.key"
    private static let label = "catussh iCloud Sync Key"
    /// What the shared access group ends in, after the team.
    private static let groupSuffix = ".me.mizorewww.rayon"

    /// The access group the keys are kept in. On the Mac it is read from the
    /// running signature, so it carries the team the app is signed by. iOS
    /// does not say; there the keychain uses the first group the signature
    /// grants, which the signing scripts make this one.
    static let accessGroup: String? = {
        #if os(macOS) || targetEnvironment(macCatalyst)
            guard let task = SecTaskCreateFromSelf(nil),
                  let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
                  as? [String]
            else { return nil }
            return groups.first { $0.hasSuffix(groupSuffix) } ?? groups.first
        #else
            return nil
        #endif
    }()

    private static func query(_ extra: [CFString: Any] = [:]) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: kCFBooleanTrue as Any,
            // The Mac's own keychain file cannot hold synchronizable items.
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        for (key, value) in extra { query[key] = value }
        return query
    }

    private static func failure(_ status: OSStatus) -> Failure {
        switch status {
        case errSecMissingEntitlement, errSecNotAvailable, errSecNoSuchKeychain:
            return .unavailable(status)
        default:
            return .failed(status)
        }
    }

    /// Whether this app can keep a key in iCloud Keychain at all.
    static var isAvailable: Bool {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query([
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnAttributes: kCFBooleanTrue as Any,
        ]) as CFDictionary, &result)
        if status == errSecSuccess || status == errSecItemNotFound { return true }
        if case .unavailable = failure(status) { return false }
        // Locked, or busy: not a reason to give up on it.
        return true
    }

    /// The keys this device has, the newest first.
    static func keys() throws -> [SyncKey] {
        var result: CFTypeRef?
        // Names first: the data of several items cannot be asked for at once
        // everywhere.
        let status = SecItemCopyMatching(query([
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: kCFBooleanTrue as Any,
        ]) as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[CFString: Any]] else { throw failure(status) }
        let accounts = items
            .sorted {
                ($0[kSecAttrCreationDate] as? Date ?? .distantPast) > ($1[kSecAttrCreationDate] as? Date ?? .distantPast)
            }
            .compactMap { $0[kSecAttrAccount] as? String }
        var keys: [SyncKey] = []
        for account in accounts {
            var data: CFTypeRef?
            let status = SecItemCopyMatching(query([
                kSecAttrAccount: account,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnData: kCFBooleanTrue as Any,
            ]) as CFDictionary, &data)
            guard status == errSecSuccess, let data = data as? Data, data.count == 32 else { continue }
            let key = SyncKey(data: data)
            // An item whose name is not its key's is not one of ours.
            if key.id == account { keys.append(key) }
        }
        return keys
    }

    static func add(_ key: SyncKey) throws {
        let status = SecItemAdd(query([
            kSecAttrAccount: key.id,
            kSecAttrLabel: label,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: key.data,
        ]) as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw failure(status) }
    }

    /// Removes every key but `kept` (all of them when nil), here and, through
    /// iCloud Keychain, on the other devices.
    static func removeKeys(except kept: String? = nil) {
        for key in (try? keys()) ?? [] where key.id != kept {
            let status = SecItemDelete(query([kSecAttrAccount: key.id]) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound {
                debugPrint("SyncKeychain: failed to remove a key: \(status)")
            }
        }
    }
}
