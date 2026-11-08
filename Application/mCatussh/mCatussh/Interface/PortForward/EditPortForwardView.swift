//
//  EditPortForwardView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/12.
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
            _bindPort = State(initialValue: String(read.bindPort))
            _targetHost = State(initialValue: read.targetHost)
            _targetPort = State(initialValue: String(read.targetPort))
            _usingMachine = State(initialValue: read.usingMachine)
        } else {
            _forwardOrientation = State(initialValue: .listenLocal)
            _bindPort = State(initialValue: "3000")
            _targetHost = State(initialValue: "127.0.0.1")
            _targetPort = State(initialValue: "3000")
            _usingMachine = State(initialValue: nil)
        }
    }

    var parsedBindPort: Int? {
        guard let value = Int(bindPort), (0 ... 65535).contains(value) else { return nil }
        return value
    }

    var parsedTargetPort: Int? {
        guard let value = Int(targetPort), (0 ... 65535).contains(value) else { return nil }
        return value
    }

    var portsValid: Bool {
        parsedBindPort != nil && parsedTargetPort != nil
    }

    var generateObject: RDPortForward {
        RDPortForward(
            forwardOrientation: forwardOrientation,
            bindPort: parsedBindPort ?? 0,
            targetHost: targetHost,
            targetPort: parsedTargetPort ?? 0,
            usingMachine: usingMachine
        )
    }

    var forwardDescription: String {
        generateObject.shortDescription()
    }

    var body: some View {
        List {
            Section {
                Picker("Forward Orientation", selection: $forwardOrientation) {
                    ForEach(RDPortForward.ForwardOrientation.allCases, id: \.self) { acase in
                        Text(acase.rawValue)
                            .tag(acase)
                    }
                }
                .pickerStyle(MenuPickerStyle())
            } header: {
                RXSectionHeader("Orientation")
            }

            Section {
                TextField("Bind Port", text: $bindPort)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numberPad)
            } header: {
                RXSectionHeader("Bind Port")
            }

            Section {
                TextField("Target Address", text: $targetHost)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                TextField("Target Port", text: $targetPort)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numberPad)
            } header: {
                RXSectionHeader("Target Host")
            }

            Section {
                Button {
                    Task { @MainActor in
                        let machine = await CatusshUtil.selectOneMachine()
                        usingMachine = machine.first
                    }
                } label: {
                    Label("Select Machine", systemImage: "arrow.right")
                        .foregroundColor(.accentColor)
                }
            } header: {
                RXSectionHeader("Machine")
            }

            Section {} footer: {
                if portsValid {
                    Text(forwardDescription)
                } else {
                    Text("Ports must be numbers between 0 and 65535")
                        .foregroundStyle(.rxDanger)
                }
            }
        }
        .rxGroupedList()
        .navigationTitle("Edit Forward")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    completeSheet()
                } label: {
                    Text("Save").bold()
                }
                .disabled(!portsValid)
            }
        }
    }

    func completeSheet() {
        guard portsValid else {
            UIBridge.presentError(with: "Invalid Port")
            return
        }
        var object = generateObject
        if let edit = inEditWith {
            object.id = edit
        }
        CatusshStore.shared.portForwardGroup.insert(object)
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
