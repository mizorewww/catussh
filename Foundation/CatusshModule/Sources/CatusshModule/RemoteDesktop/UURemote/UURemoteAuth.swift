//
//  UURemoteAuth.swift
//  CatusshModule
//
//  X-Param signing, request construction, JWT/CSRF extraction and the UU
//  Remote REST control-plane client. Mirrors /tmp/uu-refs/uu-remote-linux/src/auth.rs
//  and /tmp/uu-refs/uurc-web/frontend/src/uu/signing.ts.
//

import CryptoKit
import Foundation

public enum UUAPIError: Error, Sendable {
    case invalidURL(String)
    case transport(String)
    case http(Int, String)
    case api(Int, String)
    case missingField(String)
    case tokenExpired
}

/// Signing key shipped inside the official UU PC client (x-param-plat=1);
/// the same value for every user, so it may rotate with a client release.
public enum UUConstants {
    public static let signingKey = "alWiSzXZTLu3WfFnw13uBru3"
    public static let apiBase = "https://api.nrd.nie.163.com"
    public static let apiBaseSecondary = "https://api-dcdn.nrd.nie.163.com"
    public static let apiBaseIPv4 = "https://api-ipv4.nrd.nie.163.com"
    public static let versionName = "4.42.0.2770"
    public static let versionCode = "2770"
    public static let packageName = "com.netease.gameviewer"
    public static let channel = "gwqd"
    public static let language = "zh-CN"
    public static let country = "CN"
    public static let tokenInvalidCode = 1120
}

/// The persisted identity a logged-in UU Remote account carries.
public struct UUCredentials: Codable, Equatable, Sendable {
    public var userID: String = ""
    public var deviceID: String = ""
    public var clientID: String = ""
    public var systemID: String = ""
    public var token: String = ""
    public var csrf: String = ""
    public var guestID: String?
    public var signKey: String = UUConstants.signingKey

    public init() {}

    /// True when all fields a signed request needs are present.
    public var isComplete: Bool {
        !userID.isEmpty && !deviceID.isEmpty && !clientID.isEmpty
            && !systemID.isEmpty && !token.isEmpty && !csrf.isEmpty
    }
}

public struct UUDeviceInfo: Equatable, Sendable {
    public var deviceID: String = ""
    public var alias: String = ""
    public var status: String = ""
    public var platform: Int = 0
    public var controllable = false
    public var supportWOL = false
    public var wallpaperURL: String?
    public var versionName: String?
    public var participants: [UUParticipant] = []

    public var isOnline: Bool { status == "CONNECTED" || status == "READY" }
    public var isDesktop: Bool { platform == 1 || platform == 4 }

    public static func platformName(_ platform: Int) -> String {
        switch platform {
        case 1: "Windows"
        case 2: "Android"
        case 3: "iOS"
        case 4: "macOS"
        case 5: "TV"
        default: "Unknown"
        }
    }
}

public struct UUParticipant: Equatable, Sendable {
    public var clientID: String = ""
    public var deviceID: String = ""
    public var alias: String = ""
    public var platform: Int = 0
    public var userJoinType: String = ""
    public var controlledTime: String = ""
}

public struct UURoomConfig: Sendable {
    public var token: String = ""
    public var signalServers: [String] = []
    public var timeout: Int = 0
    public var signalReconnectDelay: Int = 0
    public var reportToken: String?
    public var reportURL: String?
    public var appDataJSON: Data?
}

public struct UUAssistRoomResult: Equatable, Sendable {
    public var canRemoteControl = false
    public var controlMode = ""
    public var code: Int = 0
    public var msg: String?
}

/// Builds the signed request the API expects: METHOD + pathWithQuery +
/// x-param-* headers (lowercase keys sorted, excluding x-param-sign) + body.
public enum UURequestSigner {
    public static func sign(
        method: String,
        pathWithQuery: String,
        headers: [String: String],
        body: Data,
        signKey: String = UUConstants.signingKey
    ) -> String {
        let base = signatureBase(method: method, pathWithQuery: pathWithQuery, headers: headers, body: body)
        let key = SymmetricKey(data: Data(signKey.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(base.utf8), using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    public static func signatureBase(
        method: String,
        pathWithQuery: String,
        headers: [String: String],
        body: Data
    ) -> String {
        let xParam = headers
            .map { ($0.key.lowercased(), $0.value) }
            .filter { $0.0.hasPrefix("x-param-") && $0.0 != "x-param-sign" }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        return "\(method.uppercased())\(pathWithQuery)\(xParam)\(String(decoding: body, as: UTF8.self))"
    }

    /// The static x-param-* headers every request carries.
    public static func commonHeaders(credentials: UUCredentials, timestamp: Int? = nil, abi: String? = nil) -> [String: String] {
        var headers: [String: String] = [
            "X-Param-CHN": UUConstants.channel,
            "X-Param-OPR": "",
            "X-Param-PKGN": UUConstants.packageName,
            "X-Param-PLAT": "4",
            "X-Param-REL": "prod",
            "X-Param-VC": UUConstants.versionCode,
            "X-Param-VN": UUConstants.versionName,
            "X-Param-TS": String(timestamp ?? Int(Date().timeIntervalSince1970)),
            "X-Param-CNT": UUConstants.country,
            "X-Param-LANG": UUConstants.language,
        ]
        if let abi { headers["X-Param-ABI"] = abi }
        if !credentials.clientID.isEmpty { headers["X-Param-client-id"] = credentials.clientID }
        if !credentials.deviceID.isEmpty { headers["X-Param-device-id"] = credentials.deviceID }
        if !credentials.systemID.isEmpty { headers["X-Param-system-id"] = credentials.systemID }
        if !credentials.userID.isEmpty { headers["X-Param-user-id"] = credentials.userID }
        if let guest = credentials.guestID, !guest.isEmpty { headers["X-Param-guest-id"] = guest }
        return headers
    }

    /// Assembles all headers for a signed request, including auth and cookies.
    ///
    /// Headers with empty values (a missing device id before registration,
    /// the always-empty `X-Param-OPR`) are dropped *before* signing so the
    /// signature covers exactly the `X-Param-*` set the wire carries —
    /// `URLRequest` cannot reliably send empty header values, and the server
    /// recomputes the signature over the headers it actually receives.
    public static func signedHeaders(
        credentials: UUCredentials,
        method: String,
        pathWithQuery: String,
        body: Data,
        timestamp: Int? = nil
    ) -> [String: String] {
        var headers = commonHeaders(credentials: credentials, timestamp: timestamp)
            .filter { !$0.value.isEmpty }
        headers["X-Param-SIGN"] = sign(
            method: method,
            pathWithQuery: pathWithQuery,
            headers: headers,
            body: body,
            signKey: credentials.signKey
        )
        if !credentials.token.isEmpty {
            headers["Authorization"] = "Bearer \(credentials.token)"
            headers["Cookie"] = "nrd_access_token=\(credentials.token);nrd_csrf_access_token=\(credentials.csrf)"
            headers["X-CSRF-TOKEN"] = credentials.csrf
        }
        return headers
    }

    /// The decoded claims of a JWT access token, or nil when it is not a JWT.
    public static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4 (JWTs strip the padding).
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The `csrf` claim inside a JWT access token.
    public static func csrf(from token: String) -> String? {
        jwtPayload(token)?["csrf"] as? String
    }

    /// The account user id inside a JWT access token (`uid`, `user_id` or
    /// `sub` — token vintages differ), for token imports that arrive without
    /// a login response to read `user_id` from.
    public static func userID(from token: String) -> String? {
        guard let claims = jwtPayload(token) else { return nil }
        for key in ["uid", "user_id", "sub"] {
            if let value = claims[key] as? String, !value.isEmpty { return value }
            if let value = claims[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }
}
