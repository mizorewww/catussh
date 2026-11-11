//
//  EditPortForwardView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/12.
//
//  New / Edit Port Forward: Local (-L), Remote (-R) or SOCKS5 (-D); bind
//  port, the server it goes through, the target, and the equivalent command.
//

import CatusshModule
import SwiftUI

struct EditPortForwardView: View {
    @Environment(\.dismiss) private var dismiss

    let inEditWith: UUID?

    @State var forwardOrientation: RDPortForward.ForwardOrientation
    @State var bindPort: String
    @State var targetHost: String
    @State var targetPort: String
    @State var usingMachine: RDMachine.ID?

    init(requestPortForward: UUID? = nil) {
        inEditWith = requestPortForward
        if let edit = requestPortForward {
            let read = CatusshStore.shared.portForwardGroup[edit]
            _forwardOrientation = State(initialValue: read.forwardOrientation)
            _bindPort = State(initialValue: read.bindPort > 0 ? String(read.bindPort) : "")
            _targetHost = State(initialValue: read.targetHost)
            _targetPort = State(initialValue: read.targetPort > 0 ? String(read.targetPort) : "")
            _usingMachine = State(initialValue: read.usingMachine)
        } else {
            _forwardOrientation = State(initialValue: .listenLocal)
            _bindPort = State(initialValue: "")
            _targetHost = State(initialValue: "127.0.0.1")
            _targetPort = State(initialValue: "")
            _usingMachine = State(initialValue: nil)
        }
    }

    var machines: [RDMachine] {
        CatusshStore.shared.machineGroup.machines
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The forward as the form describes it, on top of what is saved.
    var draft: RDPortForward {
        var result = inEditWith.map { CatusshStore.shared.portForwardGroup[$0] } ?? RDPortForward()
        result.forwardOrientation = forwardOrientation
        result.bindPort = Int(bindPort) ?? 0
        result.usingMachine = usingMachine
        result.targetHost = targetHost.trimmingCharacters(in: .whitespaces)
        result.targetPort = Int(targetPort) ?? 0
        return result
    }

    func portError(_ text: String) -> Bool {
        !text.isEmpty && (UInt16(text) == nil || text == "0")
    }

    var body: some View {
        List {
            Section {
                Picker("Orientation", selection: $forwardOrientation) {
                    Text("Local (-L)").tag(RDPortForward.ForwardOrientation.listenLocal)
                    Text("Remote (-R)").tag(RDPortForward.ForwardOrientation.listenRemote)
                    Text("SOCKS5 (-D)").tag(RDPortForward.ForwardOrientation.dynamicSOCKS)
                }
                .pickerStyle(.segmented)
            } header: {
                RXSectionHeader("Orientation")
            } footer: {
                Text(forwardOrientation.flowDescription(device: UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"))
            }

            Section {
                TextField(forwardOrientation == .dynamicSOCKS ? "1080" : "5433", text: $bindPort)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numberPad)
                    .font(.rxCode)
                Picker("Forward through", selection: $usingMachine) {
                    Text("Choose a server").tag(RDMachine.ID?.none)
                    ForEach(machines) { machine in
                        Text(machine.name).tag(RDMachine.ID?.some(machine.id))
                    }
                }
            } header: {
                RXSectionHeader("Bind Port")
            } footer: {
                if portError(bindPort) {
                    Text("The port is a number from 1 to 65535.")
                        .foregroundStyle(.rxDanger)
                }
            }

            if forwardOrientation == .dynamicSOCKS {
                Section {} footer: {
                    Text("Runs a local SOCKS5 proxy on 127.0.0.1:\(bindPort.isEmpty ? "1080" : bindPort) that tunnels all connections through the selected server (ssh -D).")
                }
            } else {
                Section {
                    TextField("127.0.0.1", text: $targetHost)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .font(.rxCode)
                    TextField("Target Port", text: $targetPort)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numberPad)
                        .font(.rxCode)
                } header: {
                    RXSectionHeader("Target Host")
                } footer: {
                    if portError(targetPort) {
                        Text("The port is a number from 1 to 65535.")
                            .foregroundStyle(.rxDanger)
                    }
                }
            }

            Section {
                CodeBlock(draft.commandPreview)
                    .opacity(draft.isValid() ? 1 : 0.5)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } header: {
                RXSectionHeader("Equivalent Command")
            }

            Section {
                Button {
                    save(start: true)
                } label: {
                    Label("Save and Start", systemImage: "play.fill")
                }
                .disabled(!draft.isValid())
            }
        }
        .rxGroupedList()
        .navigationTitle(inEditWith == nil ? "New Port Forward" : "Edit Port Forward")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save(start: false)
                } label: {
                    Text("Save").bold()
                }
                .disabled(!draft.isValid())
            }
        }
    }

    func save(start: Bool) {
        let saved = draft
        guard saved.isValid() else {
            UIBridge.presentError(with: "Incomplete Forward")
            return
        }
        CatusshStore.shared.portForwardGroup.insert(saved)
        if start {
            PortForwardBackend.shared.createSession(withPortForwardID: saved.id)
        }
        dismiss()
    }
}

struct EditPortForwardView_Previews: PreviewProvider {
    static var previews: some View {
        createPreview {
            AnyView(EditPortForwardView())
        }
    }
}
