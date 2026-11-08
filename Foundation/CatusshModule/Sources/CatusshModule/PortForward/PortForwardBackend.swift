//
//  PortForwardBackend.swift
//  CatusshModule
//
//  Shared port-forward session manager used by both macOS and iOS apps.
//

import Combine
import Foundation

@MainActor
public final class PortForwardBackend: ObservableObject {
    public static let shared = PortForwardBackend()

    private init() {}

    @Published public var container: [PortForwardContext] = []
    @Published public var lastStatus: [RDPortForward.ID: PortForwardContext.Lifecycle] = [:]

    public var onError: ((String) -> Void)?
    public var onCreated: (() -> Void)?

    public func createSession(withPortForwardID pid: RDPortForward.ID) {
        if sessionExists(withPortForwardID: pid) {
            return
        }
        let portFwd = CatusshStore.shared.portForwardGroup[pid]
        guard portFwd.isValid(),
              let mid = portFwd.usingMachine
        else {
            onError?("Invalid Info")
            return
        }
        let machine = CatusshStore.shared.machineGroup[mid]
        guard machine.isNotPlaceholder() else {
            onError?("Invalid Info")
            return
        }
        let context = PortForwardContext(
            info: portFwd,
            machine: machine
        )
        context.lifecycleHandler = { [weak self] state in
            self?.putStatus(for: pid, with: state)
        }
        context.terminationHandler = { [weak self] context in
            MainActor.assumeIsolated {
                self?.endLifecycle(for: context)
            }
        }
        container.append(context)
        context.begin()
        onCreated?()
    }

    public nonisolated func putStatus(for pid: RDPortForward.ID, with state: PortForwardContext.Lifecycle) {
        onMainThread { [weak self] in
            MainActor.assumeIsolated {
                self?.lastStatus[pid] = state
            }
        }
    }

    private func endLifecycle(for context: PortForwardContext) {
        container.removeAll { $0.id == context.id }
    }

    public func sessionExists(withPortForwardID pid: RDPortForward.ID) -> Bool {
        container.contains { $0.info.id == pid }
    }

    public func endSession(withPortForwardID pid: RDPortForward.ID) {
        let index = container.firstIndex { $0.info.id == pid }
        putStatus(for: pid, with: .terminating)
        if let index {
            let context = container.remove(at: index)
            context.terminate()
        }
    }
}
