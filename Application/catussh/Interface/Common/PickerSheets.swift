//
//  PickerSheets.swift
//  catussh (macOS)
//
//  The server picker (Open Terminals, Run snippet, Port Forward) and the identity picker.
//

import CatusshModule
import SwiftUI

struct ServerPickerSheet: View {
    let title: String
    let lead: String?
    let confirmTitle: String
    let allowsMany: Bool
    /// nil when cancelled.
    let onComplete: ([RDMachine.ID]?) -> Void

    @EnvironmentObject var store: CatusshStore
    @ObservedObject private var uuAccount = UURemoteAccountStore.shared
    @State private var selection: Set<RDMachine.ID>
    @State private var searchText = ""

    init(
        title: String,
        lead: String?,
        confirmTitle: String,
        allowsMany: Bool,
        initialSelection: Set<RDMachine.ID> = [],
        onComplete: @escaping ([RDMachine.ID]?) -> Void
    ) {
        self.title = title
        self.lead = lead
        self.confirmTitle = confirmTitle
        self.allowsMany = allowsMany
        self.onComplete = onComplete
        _selection = State(initialValue: initialSelection)
    }

    var machines: [RDMachine] {
        let all = store.machineGroup.machines.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.isQualifiedForSearch(text: searchText) }
    }

    var body: some View {
        SheetScaffold(title, lead: lead) {
            VStack(alignment: .leading, spacing: RX.Space.s3) {
                HStack(spacing: RX.Space.s2) {
                    RXSearchField("Search servers", text: $searchText, width: nil)
                    if allowsMany {
                        Button(allSelected ? "Deselect All" : "Select All") {
                            if allSelected {
                                selection.subtract(selectable.map(\.id))
                            } else {
                                selection.formUnion(selectable.map(\.id))
                            }
                        }
                        .buttonStyle(.rx)
                        .disabled(selectable.isEmpty)
                    }
                }
                ScrollView {
                    if machines.isEmpty {
                        EmptyStateView(
                            store.machineGroup.machines.isEmpty ? "No servers yet" : "No matches",
                            systemImage: "server.rack",
                        )
                    } else {
                        RXDividedStack {
                            ForEach(machines) { machine in
                                row(machine)
                            }
                        }
                        .padding(RX.Space.s2)
                    }
                }
                .frame(height: 300)
                .background(
                    RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                        .fill(Color.rxSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                                .strokeBorder(Color.rxHairline, lineWidth: 1)
                        )
                )
            }
        } footer: {
            if allowsMany {
                Text("\(selection.count) selected")
                    .font(.rxBody.monospacedDigit())
                    .foregroundStyle(.rxInkSecondary)
            }
            Spacer()
            Button("Cancel") { onComplete(nil) }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle) {
                onComplete(store.machineGroup.machines.map(\.id).filter { selection.contains($0) })
            }
            .buttonStyle(.rxPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(selection.isEmpty)
        }
        .frame(width: 520)
    }

    private var selectable: [RDMachine] { machines.filter { uuOnline($0) != false } }

    var allSelected: Bool {
        !selectable.isEmpty && selectable.allSatisfy { selection.contains($0.id) }
    }

    /// A UU Remote device has no address worth showing, only whether it is
    /// online; an offline one can't be reached for anything picked here.
    private func uuOnline(_ machine: RDMachine) -> Bool? {
        guard machine.isUURemoteDevice else { return nil }
        return uuAccount.devices.first { $0.deviceID == machine.uuDeviceID }?.isOnline ?? false
    }

    func row(_ machine: RDMachine) -> some View {
        let isSelected = selection.contains(machine.id)
        let online = uuOnline(machine)
        return Button {
            if allowsMany {
                if isSelected { selection.remove(machine.id) } else { selection.insert(machine.id) }
            } else {
                selection = [machine.id]
            }
        } label: {
            HStack(spacing: RX.Space.s3) {
                Image(systemName: allowsMany
                    ? (isSelected ? "checkmark.square.fill" : "square")
                    : (isSelected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.rxAccent : Color.rxControlBorder)
                VStack(alignment: .leading, spacing: 1) {
                    RedactableText(machine.name, redacted: store.machineRedacted == .all)
                        .font(.rxBody)
                        .foregroundStyle(.rxInk)
                    if let online {
                        Text(online ? "UU Remote · Online" : "UU Remote · Offline")
                            .font(.rxCaption)
                            .foregroundStyle(.rxInkSecondary)
                    } else {
                        RedactableText("\(machine.remoteAddress):\(machine.remotePort)", redacted: store.machineRedacted != .none)
                            .font(.rxCode)
                            .foregroundStyle(.rxInkSecondary)
                    }
                }
                Spacer()
                if !machine.group.isEmpty {
                    RXTag(machine.group)
                }
            }
            .padding(.horizontal, RX.Space.s2)
            .frame(height: RX.tableRowHeight)
            .rxRowBackground(selected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(online == false)
        .opacity(online == false ? 0.5 : 1)
    }
}

struct IdentityPickerSheet: View {
    let onComplete: (RDIdentity.ID?) -> Void

    @EnvironmentObject var store: CatusshStore
    @State private var selection: RDIdentity.ID?
    @State private var creating = false

    var body: some View {
        SheetScaffold("Choose Identity") {
            ScrollView {
                if store.identityGroup.identities.isEmpty {
                    EmptyStateView(
                        "No identities yet",
                        systemImage: "person",
                        actionTitle: "New Identity"
                    ) {
                        creating = true
                    }
                } else {
                    RXDividedStack {
                        ForEach(store.identityGroup.identities) { identity in
                            Button {
                                selection = identity.id
                            } label: {
                                HStack(spacing: RX.Space.s3) {
                                    Image(systemName: selection == identity.id ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 15))
                                        .foregroundStyle(selection == identity.id ? Color.rxAccent : Color.rxControlBorder)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(identity.username)
                                            .font(.rxBody)
                                            .foregroundStyle(.rxInk)
                                        Text(identity.authDescription)
                                            .font(.rxHelp)
                                            .foregroundStyle(.rxInkSecondary)
                                    }
                                    Spacer()
                                    if !identity.group.isEmpty { RXTag(identity.group) }
                                }
                                .padding(.horizontal, RX.Space.s2)
                                .frame(height: RX.tableRowHeight)
                                .rxRowBackground(selected: selection == identity.id)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(RX.Space.s2)
                }
            }
            .frame(height: 260)
            .background(
                RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                    .fill(Color.rxSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: RX.Radius.lg, style: .continuous)
                            .strokeBorder(Color.rxHairline, lineWidth: 1)
                    )
            )
        } footer: {
            Button {
                creating = true
            } label: {
                Label("New Identity", systemImage: "plus")
            }
            .buttonStyle(.rx)
            Spacer()
            Button("Cancel") { onComplete(nil) }
                .buttonStyle(.rx)
                .keyboardShortcut(.cancelAction)
            Button("Choose") { onComplete(selection) }
                .buttonStyle(.rxPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
        }
        .frame(width: 460)
        .sheet(isPresented: $creating) {
            IdentityEditorSheet { created in
                creating = false
                if let created { selection = created }
            }
            .environmentObject(CatusshStore.shared)
        }
    }
}
