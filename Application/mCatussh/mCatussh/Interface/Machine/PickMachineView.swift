//
//  PickMachineView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/4.
//

import CatusshModule
import SwiftUI

struct PickMachineView: View {
    @ObservedObject var store = CatusshStore.shared

    let canSelectMany: Bool

    @Binding var selection: [RDMachine.ID]
    @State var rawSelection: [RDMachine.ID] = []
    @State var searchKey = ""
    @ObservedObject var uuAccount = UURemoteAccountStore.shared

    init(selection: Binding<[RDMachine.ID]>, canSelectMany: Bool = true) {
        _selection = selection
        self.canSelectMany = canSelectMany
    }

    private var completion: (([RDMachine.ID]) -> Void)?

    /// MAKE SURE THIS VIEW IS NOT DISMISSABLE BY DRAG
    /// - Parameter completion: only called when touch checkmark button
    init(completion: @escaping (([RDMachine.ID]) -> Void), canSelectMany: Bool = true) {
        self.completion = completion
        self.canSelectMany = canSelectMany
        _selection = Binding<[RDMachine.ID]> { [] } set: { _ in }
    }

    @Environment(\.dismiss) private var dismiss

    var machines: [RDMachine] {
        let all = store.machineGroup.machines.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !searchKey.isEmpty else { return all }
        return all.filter { $0.isQualifiedForSearch(text: searchKey.lowercased()) }
    }

    /// An offline UU Remote device can't be reached for anything picked here.
    func isReachable(_ machine: RDMachine) -> Bool {
        guard machine.isUURemoteDevice else { return true }
        return uuAccount.devices.first { $0.deviceID == machine.uuDeviceID }?.isOnline ?? false
    }

    var selectable: [RDMachine] { machines.filter(isReachable) }

    var allSelected: Bool {
        !selectable.isEmpty && selectable.allSatisfy { rawSelection.contains($0.id) }
    }

    var selectionFooter: String {
        rawSelection
            .map { store.machineGroup[$0].name }
            .joined(separator: " ")
    }

    var body: some View {
        List {
            Section {
                if rawSelection.isEmpty {
                    Label("Not Selected", systemImage: "questionmark.square.dashed")
                } else {
                    Label("\(rawSelection.count) Selected", systemImage: "server.rack")
                }
            } header: {
                RXSectionHeader("Selected")
            } footer: {
                if !selectionFooter.isEmpty {
                    Text(selectionFooter)
                } else {
                    Text("<Not Available>")
                }
            }

            Section {
                if machines.isEmpty {
                    Label(store.machineGroup.machines.isEmpty ? "No servers yet" : "No matches", systemImage: "questionmark.square.dashed")
                } else {
                    ForEach(machines) { machine in
                        Button {
                            toggleSelection(for: machine.id)
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        RedactableText(machine.name, redacted: store.machineRedacted == .all)
                                            .foregroundStyle(.rxInk)
                                        if machine.isUURemoteDevice {
                                            Text(isReachable(machine) ? "UU Remote · Online" : "UU Remote · Offline")
                                                .font(.caption)
                                                .foregroundStyle(.rxInkSecondary)
                                        } else {
                                            RedactableText("\(machine.remoteAddress):\(machine.remotePort)", redacted: store.machineRedacted != .none)
                                                .font(.rxCode)
                                                .foregroundStyle(.rxInkSecondary)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: sysImage(for: machine))
                                }
                                Spacer()
                                if !machine.group.isEmpty {
                                    RXTag(machine.group)
                                }
                            }
                        }
                        .disabled(!isReachable(machine))
                    }
                }
            } header: {
                RXSectionHeader("Servers")
            }

            Section {
                if canSelectMany {
                    Button {
                        if allSelected {
                            rawSelection.removeAll { id in selectable.contains { $0.id == id } }
                        } else {
                            for machine in selectable where !rawSelection.contains(machine.id) {
                                rawSelection.append(machine.id)
                            }
                        }
                    } label: {
                        Label(allSelected ? "Deselect All" : "Select All", systemImage: "checklist")
                    }
                    .disabled(selectable.isEmpty)
                }
                Button {
                    rawSelection = []
                } label: {
                    Label("Clear Selection", systemImage: "xmark")
                }
                .disabled(rawSelection.isEmpty)
            }
        }
        .rxGroupedList()
        .searchable(text: $searchKey, prompt: "Search servers")
        .navigationTitle("Choose Servers")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                    completion?([])
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    dismiss()
                    completion?(rawSelection)
                } label: {
                    Text("Save").bold()
                }
            }
        }
        .onChange(of: rawSelection) { newValue in
            selection = newValue
        }
    }

    func sysImage(for machine: RDMachine) -> String {
        if rawSelection.contains(machine.id) {
            return "circle.fill"
        }
        return "circle.dashed"
    }

    func toggleSelection(for mid: RDMachine.ID) {
        if canSelectMany {
            if let index = rawSelection.firstIndex(of: mid) {
                rawSelection.remove(at: index)
            } else {
                rawSelection.append(mid)
            }
        } else {
            rawSelection = [mid]
        }
    }
}

struct PickMachineView_Previews: PreviewProvider {
    static var previews: some View {
        createPreview { AnyView(
            PickMachineView { result in
                debugPrint(result)
            }
        ) }
    }
}
