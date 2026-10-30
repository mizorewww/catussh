//
//  UURemoteAPIClient.swift
//  CatusshModule
//
//  REST control-plane client for NetEase UU Remote: endpoint failover,
//  request signing, JSON envelopes, and every API call the client makes.
//  Mirrors /tmp/uu-refs/uu-remote-linux/src/auth.rs and
//  /tmp/uu-refs/uurc-web/shared/src/loginFlow.ts.
//

import Foundation
import os

/// One HTTP request the API client can send.
public struct UUAPIRequest: Sendable {
    public var method: String
    public var path: String
    public var query: String?
    public var body: Data
    public var requiresAuth = true
    /// Seconds to wait for the answer; long polls hold the request open.
    public var timeout: TimeInterval = 15

    public init(method: String, path: String, query: String? = nil, body: [String: Any] = [:], requiresAuth: Bool = true) {
        self.method = method
        self.path = path
        self.query = query
        // A GET carries no body: URLSession refuses one ("resource exceeds
        // maximum size"), and the signature then covers the empty string.
        self.body = method == "GET" ? Data() : (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        self.requiresAuth = requiresAuth
    }
}

/// The `{code,msg,data}` JSON envelope every UU Remote API returns.
public struct UUAPIEnvelope<T> {
    public var code: Int
    public var msg: String
    public var data: T?
}

public actor UURemoteAPIClient {
    private let session = URLSession.shared
    private var credentials = UUCredentials()
    private var endpoints = [UUConstants.apiBase, UUConstants.apiBaseSecondary, UUConstants.apiBaseIPv4]
    private var activeEndpointIndex = 0
    private var requestCounter = 0

    public init(credentials: UUCredentials = UUCredentials()) {
        self.credentials = credentials
    }

    public func updateCredentials(_ credentials: UUCredentials) {
        self.credentials = credentials
    }

    public func currentCredentials() -> UUCredentials { credentials }

    /// Rotates to the next endpoint after 100 requests or a transport failure.
    private func nextEndpoint() -> String {
        requestCounter += 1
        if requestCounter % 100 == 0, activeEndpointIndex != 0 {
            activeEndpointIndex = 0
        }
        return endpoints[activeEndpointIndex]
    }

    private func rotateEndpointOnFailure() {
        activeEndpointIndex = (activeEndpointIndex + 1) % endpoints.count
    }

    /// Sends a signed request and unwraps the `{code,msg,data}` envelope.
    /// Retries once on a fallback endpoint after a transport failure.
    public func send<T>(_ request: UUAPIRequest) async throws -> UUAPIEnvelope<T> {
        var lastError: Error?
        for attempt in 0 ... 1 {
            do {
                let (data, response) = try await perform(request, endpoint: nextEndpoint())
                return try unwrap(data: data, response: response, request: request)
            } catch UUAPIError.tokenExpired {
                throw UUAPIError.tokenExpired
            } catch let error as UUAPIError {
                if attempt == 0, case .transport = error {
                    rotateEndpointOnFailure()
                    lastError = error
                    continue
                }
                throw error
            } catch {
                lastError = error
                throw UUAPIError.transport(error.localizedDescription)
            }
        }
        throw lastError ?? UUAPIError.transport("unknown transport failure")
    }

    private func perform(_ request: UUAPIRequest, endpoint: String) async throws -> (Data, URLResponse) {
        var pathWithQuery = request.path
        if let query = request.query, !query.isEmpty { pathWithQuery += "?\(query)" }
        guard let url = URL(string: endpoint + pathWithQuery) else {
            throw UUAPIError.invalidURL(endpoint + pathWithQuery)
        }

        var headers = UURequestSigner.signedHeaders(
            credentials: credentials,
            method: request.method,
            pathWithQuery: pathWithQuery,
            body: request.body
        )
        if !request.requiresAuth {
            headers.removeValue(forKey: "Authorization")
            headers.removeValue(forKey: "Cookie")
            headers.removeValue(forKey: "X-CSRF-TOKEN")
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("UURemote/\(UUConstants.versionName) (Macintosh; Apple Silicon)", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers where !value.isEmpty {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        do {
            return try await session.data(for: urlRequest)
        } catch {
            throw UUAPIError.transport(error.localizedDescription)
        }
    }

    private func unwrap<T>(data: Data, response: URLResponse, request: UUAPIRequest) throws -> UUAPIEnvelope<T> {
        let (status, code, msg, json) = try parse(data: data, response: response, request: request)
        guard status == 200, code == 0 else {
            // The path is for the log; the person reads what the service said.
            Self.log.error("\(request.method, privacy: .public) \(request.path, privacy: .public) refused: http \(status) code \(code)")
            throw UUAPIError.api(code, msg.isEmpty ? "code \(code)" : "\(msg) (code \(code))")
        }
        return UUAPIEnvelope(code: code, msg: msg, data: json["data"] as? T)
    }

    /// Parses the `{code,msg,data}` envelope without rejecting non-zero
    /// codes — some flows (remote-assistance join) legitimately answer
    /// `0x470` and the caller needs both the code and `data`.
    private static let log = Logger(subsystem: "me.mizorewww.rayon", category: "uu-api")

    /// Values the log may show as they are: what an answer says happened,
    /// never who or with what (tokens, ids, names, phone numbers).
    private static let loggable: Set<String> = [
        "code", "msg", "status", "publisher_availability_status", "platform", "controllable",
        "support_wol", "version_name", "international_connect", "ws_connect_timeout_ms",
        "streamer_retry_delta_ms", "max_reconnect_delta", "type", "loc",
    ]

    /// The answer's shape with only `loggable` values in it; every other
    /// string becomes its length.
    static func redacted(_ value: Any, key: String? = nil) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.reduce(into: [String: Any]()) { $0[$1.key] = redacted($1.value, key: $1.key) }
        case let array as [Any]: return array.map { redacted($0, key: key) }
        case let text as String:
            return key.map(loggable.contains) == true ? text : "…(\(text.count))"
        default: return value
        }
    }

    private func parse(data: Data, response: URLResponse, request: UUAPIRequest) throws -> (status: Int, code: Int, msg: String, json: [String: Any]) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if let object = try? JSONSerialization.jsonObject(with: data),
           let shown = try? JSONSerialization.data(withJSONObject: Self.redacted(object), options: [.sortedKeys])
        {
            Self.log.info("\(request.method, privacy: .public) \(request.path, privacy: .public) http \(status) \(String(decoding: shown.prefix(4000), as: UTF8.self), privacy: .public)")
        } else {
            Self.log.error("\(request.method, privacy: .public) \(request.path, privacy: .public) http \(status), not JSON (\(data.count) bytes)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UUAPIError.http(status, "response is not a JSON object")
        }
        let code = json["code"] as? Int ?? -1
        let msg = json["msg"] as? String ?? ""
        if code == UUConstants.tokenInvalidCode {
            throw UUAPIError.tokenExpired
        }
        // A request the service could not validate: the fields it names are
        // the useful part ("header X-Param-device-id: Field required").
        if status == 422 {
            let fields = (json["data"] as? [[String: Any]] ?? []).compactMap { item -> String? in
                let location = (item["loc"] as? [Any])?.map { "\($0)" }.joined(separator: " ")
                return [location, item["msg"] as? String].compactMap { $0 }.joined(separator: ": ")
            }
            throw UUAPIError.api(code, ([msg] + fields).filter { !$0.isEmpty }.joined(separator: "; "))
        }
        return (status, code, msg, json)
    }

    /// Sends a request and returns the raw envelope fields even when
    /// `code != 0`; transport failures still throw and rotate endpoints.
    private func sendLax(_ request: UUAPIRequest) async throws -> (status: Int, code: Int, msg: String, data: [String: Any]) {
        var lastError: Error?
        for attempt in 0 ... 1 {
            do {
                let (data, response) = try await perform(request, endpoint: nextEndpoint())
                let parsed = try parse(data: data, response: response, request: request)
                return (parsed.status, parsed.code, parsed.msg, parsed.json["data"] as? [String: Any] ?? [:])
            } catch UUAPIError.tokenExpired {
                throw UUAPIError.tokenExpired
            } catch let error as UUAPIError {
                if attempt == 0, case .transport = error {
                    rotateEndpointOnFailure()
                    lastError = error
                    continue
                }
                throw error
            } catch {
                lastError = error
                throw UUAPIError.transport(error.localizedDescription)
            }
        }
        throw lastError ?? UUAPIError.transport("unknown transport failure")
    }


    // MARK: - Device registration

    /// Registers this machine as a UU Windows host to obtain a `device_id`.
    public func deviceWindowsInit(name: String, clientID: String, systemID: String, machineGUID: String, os: String, baseBoard: String, cpu: String, video: [String], mac: String, memory: UInt64, screen: String) async throws -> String {
        let body: [String: Any] = [
            "name": name, "client_id": clientID, "system_id": systemID,
            "machine_guid": machineGUID, "os": os, "base_board": baseBoard,
            "cpu": cpu, "video": video, "mac": mac, "memory": memory, "screen": screen,
            "platform": 1, "controllable": 1,
        ]
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "POST", path: "/api/v1/device/windows/init", body: body, requiresAuth: false))
        guard let deviceID = envelope.data?["device_id"] as? String, !deviceID.isEmpty else {
            throw UUAPIError.missingField("device_id")
        }
        return deviceID
    }

    /// Registers this machine as an Android device to obtain a `device_id`.
    public func deviceAndroidInit(profile: [String: Any]) async throws -> String {
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "POST", path: "/api/v1/device/android/init", body: profile, requiresAuth: false))
        guard let deviceID = envelope.data?["device_id"] as? String, !deviceID.isEmpty else {
            throw UUAPIError.missingField("device_id")
        }
        return deviceID
    }

    // MARK: - Authentication

    /// Starts QR-code login: generates the QR content and the status ticket.
    public func qrcodeGenLogin() async throws -> (qrcodeJumpURL: String, token: String, statusQueryTicket: String) {
        // No body at all: the signature covers the empty string, as the official client sends it.
        var request = UUAPIRequest(method: "POST", path: "/api/v1/qrcode/gen/login", requiresAuth: false)
        request.body = Data()
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(request)
        guard let url = envelope.data?["qrcode_jump_url"] as? String,
              let token = envelope.data?["token"] as? String,
              let ticket = envelope.data?["status_query_ticket"] as? String
        else { throw UUAPIError.missingField("qrcode_jump_url/token/status_query_ticket") }
        return (url, token, ticket)
    }

    /// The status request is held open until the code is scanned, confirmed
    /// or expires.
    public static let qrStatusTimeout: TimeInterval = 120

    /// Long-polls QR login status: `login_status` is the last-seen value.
    public func qrcodeLoginStatus(token: String, qrcodeJumpURL: String, loginStatus: Int) async throws -> Int {
        let body: [String: Any] = ["token": token, "qrcode_jump_url": qrcodeJumpURL, "login_status": loginStatus]
        var request = UUAPIRequest(method: "POST", path: "/api/v1/qrcode/login/status", body: body, requiresAuth: false)
        request.timeout = Self.qrStatusTimeout
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(request)
        return envelope.data?["status"] as? Int ?? 1
    }

    /// Completes QR login once the user confirms on the mobile app.
    public func loginByQRCode(token: String, qrcodeJumpURL: String) async throws -> (userID: String, nickname: String, token: String) {
        let body: [String: Any] = ["token": token, "qrcode_jump_url": qrcodeJumpURL]
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "POST", path: "/api/v1/login/by_qrcode", body: body, requiresAuth: false))
        guard let data = envelope.data,
              let userID = data["user_id"] as? String,
              let token = data["token"] as? String
        else { throw UUAPIError.missingField("user_id/token") }
        return (userID, data["nickname"] as? String ?? "", token)
    }

    /// Sends an SMS verification code for passwordless login.
    public func mobileCode(countryCode: String, mobile: String) async throws {
        let body: [String: Any] = ["country_code": countryCode, "mobile": mobile, "type": "login"]
        let _: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "POST", path: "/api/v1/security/mobile/code", body: body, requiresAuth: false))
    }

    /// Completes SMS login.
    public func loginByMobile(countryCode: String, mobile: String, code: String) async throws -> (userID: String, nickname: String, token: String) {
        let body: [String: Any] = ["country_code": countryCode, "mobile": mobile, "code": code]
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "POST", path: "/api/v1/login/by_mobile", body: body, requiresAuth: false))
        guard let data = envelope.data,
              let userID = data["user_id"] as? String,
              let token = data["token"] as? String
        else { throw UUAPIError.missingField("user_id/token") }
        return (userID, data["nickname"] as? String ?? "", token)
    }

    // MARK: - Devices

    /// Every desktop/mobile/TV device under the current account.
    public func deviceGroupsOfMy() async throws -> [UUDeviceInfo] {
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "GET", path: "/api/v1/device/groups/of/my"))
        guard let data = envelope.data else { return [] }
        var devices: [UUDeviceInfo] = []
        for key in ["desktop_devices", "mobile_devices", "tv_devices"] {
            guard let list = data[key] as? [[String: Any]] else { continue }
            devices.append(contentsOf: list.compactMap(Self.device(from:)))
        }
        return devices
    }

    /// The legacy flat device list (`/api/v1/device/list`).
    public func deviceList() async throws -> [UUDeviceInfo] {
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "GET", path: "/api/v1/device/list"))
        guard let data = envelope.data else { return [] }
        var devices: [UUDeviceInfo] = []
        for key in ["current_device", "my_binded_devices", "others_shared_devices"] {
            guard let list = data[key] as? [[String: Any]] else { continue }
            devices.append(contentsOf: list.compactMap(Self.device(from:)))
        }
        return devices
    }

    /// The service sends some flags as JSON booleans and some as 0 / 1.
    private static func flag(_ value: Any?) -> Bool {
        (value as? Bool) ?? ((value as? Int).map { $0 != 0 } ?? false)
    }

    static func device(from json: [String: Any]) -> UUDeviceInfo? {
        guard let deviceID = json["device_id"] as? String else { return nil }
        var device = UUDeviceInfo()
        device.deviceID = deviceID
        device.alias = json["alias"] as? String ?? ""
        device.status = json["status"] as? String ?? ""
        device.platform = json["platform"] as? Int ?? 0
        device.controllable = flag(json["controllable"])
        device.supportWOL = flag(json["support_wol"])
        device.wallpaperURL = json["wallpaper_url"] as? String
        device.versionName = json["version_name"] as? String
        if let participants = json["participants_info"] as? [[String: Any]] {
            device.participants = participants.map { item in
                UUParticipant(
                    clientID: item["client_id"] as? String ?? "",
                    deviceID: item["device_id"] as? String ?? "",
                    alias: item["alias"] as? String ?? "",
                    platform: item["platform"] as? Int ?? 0,
                    userJoinType: item["user_join_type"] as? String ?? "",
                    controlledTime: item["controlled_time"] as? String ?? ""
                )
            }
        }
        return device
    }

    // MARK: - Room bootstrap

    /// Joins a device's room to get the signaling token, servers and timeouts.
    public func roomJoinByDevice(_ deviceID: String, forceJoin: Bool = true) async throws -> UURoomConfig {
        let body: [String: Any] = ["force_join": forceJoin]
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "POST", path: "/api/v1/room/join/by_device/\(deviceID)", body: body))
        guard let data = envelope.data, let config = Self.roomConfig(from: data) else {
            let keys = envelope.data.map { $0.keys.sorted().joined(separator: ", ") } ?? "no data"
            throw UUAPIError.missingField("the room token and signaling servers (it sent: \(keys))")
        }
        return config
    }

    /// Clears the room a device previously joined.
    public func roomClearByDevice(_ deviceID: String) async throws {
        let _: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "POST", path: "/api/v1/room/clear/by_device/\(deviceID)", body: [:]))
    }

    // MARK: - Remote assistance

    /// Checks whether a connect-id accepts remote control right now.
    public func shareControlMode(connectID: String) async throws -> UUAssistRoomResult {
        let body: [String: Any] = ["connect_id": connectID]
        let envelope: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "POST", path: "/api/v2/room/share/control_mode", body: body))
        guard let data = envelope.data else { throw UUAPIError.missingField("data") }
        var result = UUAssistRoomResult()
        result.canRemoteControl = (data["can_remote_control"] as? Bool) ?? false
        result.controlMode = data["control_mode"] as? String ?? ""
        return result
    }

    /// The response code the assistance API returns while the host still
    /// has to confirm the request (`CONFIRMATION_REQUIRED_CODE` upstream).
    public static let confirmationRequiredCode = 0x470 // 1136

    /// A room's connection details. The service answers flat (`token`,
    /// `signaling_server`, `signaling_list`, …); older answers nested them
    /// under `room_config` with `signal_servers`.
    static func roomConfig(from data: [String: Any]) -> UURoomConfig? {
        let config = data["room_config"] as? [String: Any] ?? data
        guard let token = config["token"] as? String, !token.isEmpty else { return nil }
        var result = UURoomConfig()
        result.token = token
        var servers = config["signal_servers"] as? [String] ?? []
        if let primary = config["signaling_server"] as? String { servers.append(primary) }
        servers += config["signaling_list"] as? [String] ?? []
        // In order, once each: the primary first.
        result.signalServers = servers.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        guard !result.signalServers.isEmpty else { return nil }
        // Both in milliseconds, as the signaling client reads them.
        result.timeout = config["timeout"] as? Int ?? config["ws_connect_timeout_ms"] as? Int ?? 16000
        result.signalReconnectDelay = config["signal_reconnect_delay"] as? Int ?? config["streamer_retry_delta_ms"] as? Int ?? 1000
        result.reportToken = config["report_token"] as? String
        result.reportURL = config["report_url"] as? String
        result.appDataJSON = config["app_data"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return result
    }

    /// Deep search for a string field inside a nested response — upstream
    /// reads `control_id` the same way (`readNestedString`).
    private static func nestedString(_ value: Any?, key: String) -> String? {
        if let dict = value as? [String: Any] {
            if let direct = dict[key] as? String, !direct.isEmpty { return direct }
            for child in dict.values {
                if let found = nestedString(child, key: key) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = nestedString(child, key: key) { return found }
            }
        }
        return nil
    }

    /// Joins a remote-assistance room by connect-id + verification code.
    /// Tries the v2 endpoint first, falls back to v1 on 404/405 (upstream's
    /// `join_share`), and when the answer is `0x470` the host still has to
    /// confirm — poll `by_confirmation` until the room opens.
    public func joinShareByCode(connectID: String, code: String) async throws -> UURoomConfig {
        let body: [String: Any] = ["connect_id": connectID, "connect_code": code]
        var lastError: Error = UUAPIError.api(-1, "join by_code failed")
        var response: (status: Int, code: Int, msg: String, data: [String: Any])?
        for version in [2, 1] {
            do {
                response = try await sendLax(UUAPIRequest(method: "POST", path: "/api/v\(version)/room/join/share/by_code", body: body))
                break
            } catch let error as UUAPIError {
                // A missing endpoint may answer HTML; only v2 falls back.
                if version == 2, case let .http(status, _) = error, status == 404 || status == 405 {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        guard let response else { throw lastError }
        if response.code == 0, let config = Self.roomConfig(from: response.data) {
            return config
        }
        guard response.code == Self.confirmationRequiredCode else {
            throw UUAPIError.api(response.code, "join share by_code: http \(response.status) code \(response.code) \(response.msg)")
        }

        // The host has to confirm: poll by_confirmation with the control_id
        // the pending request returned (if any) until the room materializes.
        let controlID = Self.nestedString(response.data, key: "control_id")
        var attempts = 0
        while attempts < 60 {
            attempts += 1
            try await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                return try await joinShareByConfirmation(connectID: connectID, controlID: controlID)
            } catch let error as UUAPIError {
                if case let .api(code, _) = error,
                   code == Self.confirmationRequiredCode || code == -1 {
                    continue // still waiting for the host to accept
                }
                throw error
            }
        }
        throw UUAPIError.api(Self.confirmationRequiredCode, "the host did not confirm the remote-assistance request in time")
    }

    /// Joins a remote-assistance room after the host confirmed. Non-zero
    /// codes throw `UUAPIError.api` — `0x470` means "still waiting".
    public func joinShareByConfirmation(connectID: String, controlID: String? = nil) async throws -> UURoomConfig {
        var body: [String: Any] = ["connect_id": connectID]
        if let controlID { body["control_id"] = controlID }
        let response = try await sendLax(UUAPIRequest(method: "POST", path: "/api/v2/room/join/share/by_confirmation", body: body))
        if response.code == 0, let config = Self.roomConfig(from: response.data) {
            return config
        }
        throw UUAPIError.api(response.code, "join share by_confirmation: http \(response.status) code \(response.code) \(response.msg)")
    }

    /// Cancels a remote-assistance request.
    public func cancelRemoteAssist(connectID: String) async throws {
        let body: [String: Any] = ["connect_id": connectID]
        let _: UUAPIEnvelope<[String: Any]> = try await send(UUAPIRequest(method: "POST", path: "/api/v2/room/share/cancel_remote_assist", body: body))
    }
}
