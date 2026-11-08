// MIT LICENSE
// Trimmed-down derivative of https://github.com/kishikawakatsumi/KeychainAccess
// keeping only the generic-password surface catussh uses (service-scoped string
// get/set/remove with label/comment). The original MIT license applies.
//
//  Keychain.swift
//  KeychainAccess
//
//  Created by kishikawa katsumi on 2014/12/24.
//  Copyright (c) 2014 kishikawa katsumi. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import Security

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain error \(status)"
    }
}

/// Service-scoped generic-password keychain access.
public final class Keychain {
    public let service: String
    private var labelValue: String?
    private var commentValue: String?

    public init(service: String) {
        self.service = service
    }

    private init(service: String, label: String?, comment: String?) {
        self.service = service
        labelValue = label
        commentValue = comment
    }

    public func label(_ label: String) -> Keychain {
        Keychain(service: service, label: label, comment: commentValue)
    }

    public func comment(_ comment: String) -> Keychain {
        Keychain(service: service, label: labelValue, comment: comment)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    /// Returns the string for `key`, or nil when no such item exists.
    public func getString(_ key: String) throws -> String? {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanTrue

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8)
            else {
                throw KeychainError(status: errSecParam)
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Adds or updates the item, applying any chained label/comment.
    public func set(_ value: String, key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError(status: errSecParam)
        }

        var lookup = baseQuery
        lookup[kSecAttrAccount as String] = key

        var attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if let labelValue { attributes[kSecAttrLabel as String] = labelValue }
        if let commentValue { attributes[kSecAttrComment as String] = commentValue }

        var insert = lookup
        attributes.forEach { insert[$0] = $1 }
        let add = SecItemAdd(insert as CFDictionary, nil)
        switch add {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
            guard update == errSecSuccess else {
                throw KeychainError(status: update)
            }
        default:
            throw KeychainError(status: add)
        }
    }

    /// Removes the item; removing a missing key is not an error.
    public func remove(_ key: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
