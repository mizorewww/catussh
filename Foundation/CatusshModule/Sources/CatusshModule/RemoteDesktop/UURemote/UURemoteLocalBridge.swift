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

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

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

    /// `uuremote://external/device/authorize?callback=…&nonce=…` — asks the
    /// mobile app to authorize this device so it can be controlled. The
    /// app picks the device and calls back with `anonymous_device_id`.
    public static func authorizeURL(callback: String, nonce: String) -> URL? {
        var components = URLComponents(string: "uuremote://external/device/authorize")
        components?.queryItems = [
            URLQueryItem(name: "callback", value: callback),
            URLQueryItem(name: "nonce", value: nonce),
        ]
        return components?.url
    }

    /// `uuremote://external/device/control?anonymous_device_id=…&window_type=1`
    /// — opens remote control; `window_type=1` gives the floating-PiP
    /// layout. `anonymous_device_id` comes from an authorize callback.
    public static func controlURL(anonymousDeviceID: String, windowType: Int = 1, callback: String? = nil) -> URL? {
        var components = URLComponents(string: "uuremote://external/device/control")
        var items = [
            URLQueryItem(name: "anonymous_device_id", value: anonymousDeviceID),
            URLQueryItem(name: "window_type", value: "\(windowType)"),
        ]
        if let callback {
            items.append(URLQueryItem(name: "callback", value: callback))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Whether the official UU Remote app is installed (iOS: via the
    /// `uuremote` query scheme the app's Info.plist must declare).
    public static var officialAppInstalled: Bool {
        guard let url = URL(string: "uuremote://") else { return false }
        #if canImport(UIKit)
            return UIApplication.shared.canOpenURL(url)
        #elseif canImport(AppKit)
            return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        #else
            return false
        #endif
    }

    /// The URL scheme this app registers for UU Remote callbacks.
    public static let callbackScheme = "catussh"

    /// Kicks the official app's authorize flow for a machine. The nonce is
    /// the machine's UUID so `handleCallback` can match the answer.
    @MainActor
    public static func openAuthorizeInOfficialApp(for machine: RDMachine) {
        guard let url = authorizeURL(
            callback: "\(callbackScheme)://uuremote-authorize",
            nonce: machine.id.uuidString
        ) else { return }
        openExternalURL(url)
    }

    /// Opens remote control in the official app. On macOS the device's own
    /// `uuremote://` endpoints are not implemented, so `uuyc-cli device
    /// connect` does the handoff when the CLI is around; on iOS the
    /// `uuAnonymousDeviceID` stored by an earlier authorize drives
    /// `device/control`, or the authorize flow runs first.
    @MainActor
    public static func openControlInOfficialApp(for machine: RDMachine) {
        #if os(macOS)
            if cliInstalled {
                try? cliConnect(deviceID: machine.uuDeviceID)
            } else if let url = URL(string: "uuremote://") {
                openExternalURL(url)
            }
            return
        #endif
        if machine.uuAnonymousDeviceID.isEmpty {
            openAuthorizeInOfficialApp(for: machine)
            return
        }
        guard let url = controlURL(
            anonymousDeviceID: machine.uuAnonymousDeviceID,
            windowType: 1,
            callback: "\(callbackScheme)://uuremote-control"
        ) else { return }
        openExternalURL(url)
    }

    /// Handles `catussh://uuremote-…` callbacks from the official app:
    /// authorize answers store the encrypted `anonymous_device_id` on the
    /// machine (and immediately continue into control); control answers
    /// only need their status surfaced. Returns true when the URL was one
    /// of ours.
    @MainActor
    @discardableResult
    public static func handleCallback(_ url: URL) -> Bool {
        guard url.scheme == callbackScheme, let host = url.host else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        switch host {
        case "uuremote-authorize":
            guard value("status") == "success",
                  let anonymous = value("anonymous_device_id"), !anonymous.isEmpty,
                  let nonce = value("nonce"), let machineID = UUID(uuidString: nonce)
            else { return true }
            var machine = CatusshStore.shared.machineGroup[machineID]
            guard machine.isNotPlaceholder() else { return true }
            machine.uuAnonymousDeviceID = anonymous
            CatusshStore.shared.machineGroup[machineID] = machine
            openControlInOfficialApp(for: machine)
            return true
        case "uuremote-control":
            return true
        default:
            return false
        }
    }

    private static func openExternalURL(_ url: URL) {
        #if canImport(UIKit)
            UIApplication.shared.open(url)
        #elseif canImport(AppKit)
            NSWorkspace.shared.open(url)
        #endif
    }

    /// True when the official uuyc-cli binary is installed. Only native
    /// macOS can spawn a `Process`, so the bridge reports unavailable on
    /// iOS and Mac Catalyst.
    public static var cliInstalled: Bool {
        #if os(macOS) && !targetEnvironment(macCatalyst)
            return FileManager.default.isExecutableFile(atPath: uuCLIPath)
        #else
            return false
        #endif
    }

    /// Runs `uuyc-cli <subcommand> <args>` and returns its JSON output.
    public static func runCLI(_ arguments: [String], timeout: TimeInterval = 15) throws -> Data {
        #if os(macOS) && !targetEnvironment(macCatalyst)
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
        #else
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "uuyc-cli is only available on macOS"])
        #endif
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

    /// `uuyc-cli device connect <device_id>` → opens the official remote-control window.
    public static func cliConnect(deviceID: String) throws {
        _ = try runCLI(["device", "connect", deviceID])
    }

    /// `uuyc-cli assist start <connect_id>` → asks to control an assisted device.
    public static func cliAssistStart(connectID: String) throws {
        _ = try runCLI(["assist", "start", connectID])
    }

    /// `uuyc-cli term <device_id>` → opens a terminal session.
    public static func cliTerminal(deviceID: String) throws {
        _ = try runCLI(["term", deviceID])
    }
}
