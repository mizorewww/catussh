//
//  VNCDiscovery.swift
//  CatusshModule
//
//  Screen-sharing hosts on the local network: Bonjour's `_rfb._tcp`, which
//  macOS Screen Sharing and most VNC servers advertise. Each service is
//  resolved to its host name (`MacbookProM2.local`), which outlives the
//  address DHCP hands out.
//

import Foundation

/// One advertised screen-sharing service.
public struct VNCDiscoveredHost: Identifiable, Equatable, Sendable {
    /// The service name, unique on the network ("Macbook_Pro_M2").
    public var id: String { name }
    public var name: String
    /// The resolved host name without the trailing dot; empty until resolved.
    public var hostName: String
    public var port: Int

    /// The service name as people write it: underscores read as spaces.
    public var displayName: String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    /// Whether a saved server already points at this host.
    public func matches(_ machine: RDMachine) -> Bool {
        guard machine.remoteDesktopProtocol == .vnc, !hostName.isEmpty else { return false }
        let address = machine.remoteAddress.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return address == hostName.lowercased() && (Int(machine.vncPort) ?? 5900) == port
    }

    /// A VNC server for this host. A Mac asks for an account (Apple
    /// authentication), so the user name and password are left to the editor.
    public func makeMachine() -> RDMachine {
        var machine = RDMachine(remoteAddress: hostName, remotePort: "22", name: displayName)
        machine.remoteDesktopProtocol = .vnc
        machine.vncPort = String(port)
        return machine
    }
}

/// Browses `_rfb._tcp` while something shows the result. Browsing runs on the
/// main run loop; start and stop from the main thread.
@MainActor
public final class VNCDiscovery: NSObject, ObservableObject {
    public static let shared = VNCDiscovery()

    @Published public private(set) var hosts: [VNCDiscoveredHost] = []
    /// Why browsing stopped, e.g. local network access was refused.
    @Published public private(set) var failure: String?
    /// True for the first seconds of browsing, while nothing found yet
    /// means little.
    @Published public private(set) var isSearching = false

    private var browser: NetServiceBrowser?
    /// Services found and being resolved, by name; kept so the resolve
    /// callbacks have a live object.
    private var services: [String: NetService] = [:]
    private var watchers = 0

    /// Starts browsing for the first watcher.
    public func start() {
        watchers += 1
        guard browser == nil else { return }
        failure = nil
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: "_rfb._tcp.", inDomain: "local.")
        self.browser = browser
        isSearching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated { self?.isSearching = false }
        }
    }

    /// Stops once the last watcher is gone.
    public func stop() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        browser?.stop()
        browser = nil
        services.values.forEach { $0.stop() }
        services.removeAll()
        hosts.removeAll()
    }

    private func found(_ service: NetService) {
        services.removeValue(forKey: service.name)?.stop()
        services[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    private func resolved(_ service: NetService) {
        guard let hostName = service.hostName, service.port > 0 else { return }
        let host = VNCDiscoveredHost(
            name: service.name,
            hostName: hostName.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            port: service.port
        )
        hosts.removeAll { $0.name == host.name }
        hosts.append(host)
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func removed(_ service: NetService) {
        services.removeValue(forKey: service.name)?.stop()
        hosts.removeAll { $0.name == service.name }
    }
}

// The browser and services are scheduled on the main run loop, so their
// callbacks arrive on the main thread.
extension VNCDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    public nonisolated func netServiceBrowser(_: NetServiceBrowser, didFind service: NetService, moreComing _: Bool) {
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated { found(service) }
    }

    public nonisolated func netServiceBrowser(_: NetServiceBrowser, didRemove service: NetService, moreComing _: Bool) {
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated { removed(service) }
    }

    public nonisolated func netServiceBrowser(_: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        MainActor.assumeIsolated {
            browser = nil
            // -72008: the app may not browse (no local network access, or
            // the service type is not declared in NSBonjourServices).
            failure = code == -72008
                ? "catussh may not look on the local network. Allow it in System Settings › Privacy & Security › Local Network."
                : "Could not look for screen-sharing hosts (\(code))."
        }
    }

    public nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        nonisolated(unsafe) let sender = sender
        MainActor.assumeIsolated { resolved(sender) }
    }
}
