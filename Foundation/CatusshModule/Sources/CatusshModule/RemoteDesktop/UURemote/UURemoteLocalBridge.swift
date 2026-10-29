//
//  UURemoteLocalBridge.swift
//  CatusshModule
//
//  Optional local helpers: the official `uuremote://` URL scheme (iOS/Android
//  remote-control handoff) and the installed `uuyc-cli` command-line client at
//  /Applications/UURemote.app/Contents/Helpers/uuyc-cli. These wrap the
//  first-party integrations the user may already have; the native driver above
//  is what actually runs a session.
//

import Foundation

public enum UULocalBridge {
    /// Path of the official UU Remote command-line client on macOS.
    public static let uuCLIPath = "/Applications/UURemote.app/Contents/Helpers/uuyc-cli"

    /// Builds a `uuremote://` URL the official iOS/Android app understands.
    /// Supported since v4.42.0; iOS opens UU directly, Android lands on an
    /// intermediate page first.
    public static func makeURL(action: String, deviceID: String, extra: [String: String] = [:]) -> URL? {
        var components = URLComponents(string: "uuremote://external/\(action)")
        var items = extra.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "device_id", value: deviceID))
        components?.queryItems = items
        return components?.url
    }

    /// `uuremote://external/device/authorize?device_id=…` — asks the mobile app
    /// to authorize this device so it can be controlled.
    public static func authorizeURL(deviceID: String) -> URL? {
        makeURL(action: "device/authorize", deviceID: deviceID)
    }

    /// `uuremote://external/control?device_id=…&window_type=1` — opens remote
    /// control; `window_type=1` gives the floating-PiP layout.
    public static func controlURL(deviceID: String, windowType: Int = 1) -> URL? {
        makeURL(action: "control", deviceID: deviceID, extra: ["window_type": "\(windowType)"])
    }

    /// True when the official uuyc-cli binary is installed.
    public static var cliInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: uuCLIPath)
    }

    /// Runs `uuyc-cli <subcommand> <args>` and returns its JSON output.
    public static func runCLI(_ arguments: [String], timeout: TimeInterval = 15) throws -> Data {
        guard cliInstalled else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "uuyc-cli not installed"])
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uuCLIPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "uuyc-cli exited \(process.terminationStatus)"])
        }
        return data
    }

    /// `uuyc-cli status` → `[String: Any]`.
    public static func cliStatus() throws -> [String: Any] {
        let data = try runCLI(["status"])
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// `uuyc-cli device list` → device descriptors.
    public static func cliDeviceList() throws -> [[String: Any]] {
        let data = try runCLI(["device", "list"])
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// `uuyc-cli connect <device_id>` → opens the official remote-control window.
    public static func cliConnect(deviceID: String) throws {
        _ = try runCLI(["connect", deviceID])
    }

    /// `uuyc-cli term <device_id>` → opens a terminal session.
    public static func cliTerminal(deviceID: String) throws {
        _ = try runCLI(["term", deviceID])
    }
}
