//
//  FileTransferView.swift
//  mCatussh
//
//  Created by Lakr Aream on 2022/3/18.
//

import CatusshModule
import SwiftUI
import UIKit

struct FileTransferView: View {
    @ObservedObject var context: FileTransferContext
    @Environment(\.dismiss) private var dismiss

    @State var openFilePicker: Bool = false
    @State var searchKey: String = ""
    /// The remote file open in the editor.
    @State var editing: EditedFile?

    struct EditedFile: Identifiable {
        let path: String
        var id: String { path }
    }

    var fileList: [FileTransferContext.RemoteFile] {
        if searchKey.isEmpty {
            return context.currentFileList
        }
        let key = searchKey.lowercased()
        return context.currentFileList
            .filter { file in
                if file.name.lowercased().contains(key) {
                    return true
                }
                return false
            }
    }

    var body: some View {
        Group {
            if context.destroyedSession {
                EmptyStateView("Connection closed", systemImage: "bolt.horizontal")
            } else {
                VStack(spacing: RX.Space.s3) {
                    mainView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    bottomToolbar
                        .disabled(context.processConnection)
                        .disabled(context.isProgressRunning)
                    hintView
                }
            }
        }
        .padding(.horizontal, RX.Space.s4)
        .padding(.bottom, RX.Space.s3)
        .background(RXBackdrop().ignoresSafeArea())
        .animation(.interactiveSpring(), value: context.currentFileList)
        .animation(.interactiveSpring(), value: context.currentHint)
        .animation(.interactiveSpring(), value: context.currentProcessingFile)
        .animation(.interactiveSpring(), value: context.processConnection)
        .navigationTitle(context.machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $editing) { file in
            RemoteFileEditorView(context: context, remotePath: file.path)
        }
    }

    var mainView: some View {
        Group {
            if context.isProgressRunning || context.processConnection {
                progressView
            } else if !context.connected {
                EmptyStateView(
                    "Connection closed",
                    systemImage: "bolt.horizontal",
                    message: context.connectionPhase == .closed ? "" : context.currentHint,
                    actionTitle: "Reconnect"
                ) {
                    context.processBootstrap()
                }
                .rxCard()
            } else {
                fileListView
            }
        }
    }

    var hintView: some View {
        Group {
            if !context.currentHint.isEmpty {
                HelpText(context.currentHint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var progressView: some View {
        let total = context.totalProgress
        let current = context.currentProgress
        let fraction: Double? = total.totalUnitCount > 0
            ? total.fractionCompleted
            : (current.totalUnitCount > 0 ? current.fractionCompleted : nil)
        let name = context.currentProcessingFile.isEmpty
            ? (context.currentHint.isEmpty ? "Working…" : context.currentHint)
            : URL(fileURLWithPath: context.currentProcessingFile).lastPathComponent
        return VStack(alignment: .leading, spacing: RX.Space.s2) {
            CardHead("Transfer")
            ProgressRowView(
                title: name,
                detail: context.currentSpeed > 0 ? RXFormat.rateString(Double(context.currentSpeed)) : "",
                fraction: fraction,
                cancel: context.currentProgressCancelable && context.continueCurrentProgress
                    ? { context.continueCurrentProgress = false }
                    : nil
            )
        }
        .rxCard()
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, RX.Space.s3)
    }

    var fileListView: some View {
        Group {
            if context.currentFileList.isEmpty {
                EmptyStateView("Empty folder", systemImage: "folder")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: RX.Space.s2) {
                        CapsLabel("\(fileList.count) item\(fileList.count == 1 ? "" : "s")")
                            .padding(.leading, RX.Space.s2)
                        RXDividedStack {
                            ForEach(fileList) { file in
                                RemoteFileElement(file: file, context: context) { path in
                                    editing = EditedFile(path: path)
                                }
                            }
                        }
                        .rxCard(padding: RX.Space.s2)
                    }
                    .padding(.top, RX.Space.s3)
                }
                .searchable(text: $searchKey)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var bottomToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                if !context.connected {
                    makeFloatingButton("arrow.counterclockwise") {
                        context.processBootstrap()
                    }
                }
                makeFloatingButton("xmark") {
                    if context.connected {
                        context.processShutdown()
                    } else {
                        FileTransferManager.shared.end(for: context.id)
                        dismiss()
                    }
                }
                // stays available while a connection attempt hangs
                .environment(\.isEnabled, true)
                Divider().frame(height: 20)
                makeFloatingButton("doc.viewfinder") {
                    UIBridge.openFileContainer()
                }
                makeFloatingButton("folder.badge.plus") {
                    UIBridge.askForInputText(
                        title: "New Folder",
                        message: "",
                        placeholder: "Folder Name",
                        payload: "",
                        canCancel: true
                    ) { name in
                        guard name.isValidAsFilename else {
                            UIBridge.presentError(with: "Invalid Filename")
                            return
                        }
                        context.createFolder(with: name)
                    }
                }
                .disabled(!context.connected)
                makeFloatingButton("arrow.up.doc") {
                    openFilePicker = true
                }
                .sheet(isPresented: $openFilePicker, onDismiss: nil) {
                    FilePickerUIRepresentable(types: [.item], allowMultiple: true) { urls in
                        debugPrint(urls)
                        context.upload(urls: urls)
                    }
                }
                .disabled(!context.connected)
                makeFloatingButton("arrow.clockwise") {
                    context.loadCurrentFileList()
                }
                .disabled(!context.connected)
                Divider().frame(height: 20)
                makeFloatingButton("arrow.right") {
                    UIBridge.askForInputText(
                        title: "Navigator",
                        message: "",
                        placeholder: "Remote Path",
                        payload: context.currentDir,
                        canCancel: true
                    ) { path in
                        guard !path.isEmpty, path.hasPrefix("/") else {
                            UIBridge.presentError(with: "Invalid Path")
                            return
                        }
                        context.navigate(path: path)
                    }
                }
                .disabled(!context.connected)
                pathItems
                    .disabled(!context.connected)
            }
        }
        .frame(maxWidth: .infinity)
    }

    var pathItems: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< context.currentUrl.pathComponents.count, id: \.self) { idx in
                Button {
                    rollToPath(with: idx)
                } label: {
                    Text(context.currentUrl.pathComponents[idx])
                        .font(.system(size: 13, weight: idx == context.currentUrl.pathComponents.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == context.currentUrl.pathComponents.count - 1 ? Color.rxInk : Color.rxInkSecondary)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                if idx != context.currentUrl.pathComponents.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.rxInkTertiary)
                }
            }
        }
    }

    func rollToPath(with index: Int) {
        var url = context.currentUrl
        let cnt = index + 1
        while url.pathComponents.count > cnt, !url.pathComponents.isEmpty {
            url.deleteLastPathComponent()
        }
        debugPrint(url.path)
        context.currentDir = url.path
        context.loadCurrentFileList()
    }

    func makeFloatingButton(_ image: String, block: @escaping () -> Void) -> some View {
        Button {
            block()
        } label: {
            Image(systemName: image)
                .font(.system(size: 15))
                .frame(width: 36, height: 32)
        }
        .buttonStyle(.rx(iconOnly: false))
    }

    struct RemoteFileElement: View {
        let file: FileTransferContext.RemoteFile
        @ObservedObject var context: FileTransferContext
        let edit: (String) -> Void

        private var tooLargeToEdit: Bool {
            (file.fstat.size?.int64Value ?? 0) > FileTransferContext.editableSizeLimit
        }

        var body: some View {
            Menu {
                if !file.fstat.isDirectory {
                    Section {
                        Button {
                            edit(context.currentUrl.appendingPathComponent(file.name).path)
                        } label: {
                            Label(tooLargeToEdit ? "Too Large to Edit" : "Edit", systemImage: "square.and.pencil")
                        }
                        .disabled(tooLargeToEdit)
                    }
                }
                if file.fstat.isDirectory {
                    Section {
                        Button {
                            let path = context.currentUrl.appendingPathComponent(file.name).path
                            context.navigate(path: path)
                        } label: {
                            Label("Open", systemImage: "arrow.right")
                        }
                    }
                }
                Section {
                    Button {
                        UIBridge.sendPasteboard(str: file.name)
                    } label: {
                        Label("Copy Name", systemImage: "")
                    }
                    Button {
                        let path = context.currentUrl.appendingPathComponent(file.name).path
                        UIBridge.sendPasteboard(str: path)
                    } label: {
                        Label("Copy Path", systemImage: "")
                    }
                }
                Section {
                    Button {
                        UIBridge.askForInputText(
                            title: "Rename",
                            message: "",
                            placeholder: "New File Name",
                            payload: file.name,
                            canCancel: true
                        ) { newValue in
                            guard newValue.isValidAsFilename else {
                                UIBridge.presentError(with: "Invalid Filename")
                                return
                            }
                            let base = context.currentUrl
                            context.rename(
                                from: base.appendingPathComponent(file.name),
                                to: base.appendingPathComponent(newValue)
                            )
                        }
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                }
                Section {
                    Button {
                        let remoteUrl = context.currentUrl.appendingPathComponent(file.name)
                        let documentDir = FileManager
                            .default
                            .urls(for: .documentDirectory, in: .userDomainMask)[0]
                        let base = documentDir
                        context.download(from: remoteUrl, toDir: base)
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                    }
                }
                Section {
                    Button {
                        let item = context.currentUrl.appendingPathComponent(file.name)
                        UIBridge.requiresConfirmation(
                            message: "Are you sure you want to delete \(item.path)?"
                        ) { y in
                            if y { context.delete(item: item) }
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                }
            } label: {
                content
            }
        }

        var content: some View {
            HStack(spacing: RX.Space.s3) {
                Image(systemName: sfAvatar)
                    .foregroundStyle(file.fstat.isDirectory ? Color.rxAccent : Color.rxInkSecondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .foregroundStyle(.rxInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.fstat.isDirectory ? file.fstat.permissionDescription : "\(size) · \(file.fstat.permissionDescription)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.rxInkSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .foregroundStyle(.rxInkTertiary)
            }
            .padding(.horizontal, RX.Space.s2)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }

        var sfAvatar: String {
            if file.fstat.isDirectory {
                return "folder"
            }
            if file.fstat.isLink {
                return "link"
            }
            return "doc"
        }

        var size: String {
            RXFormat.bytesString(Double(truncating: file.fstat.size ?? 0))
        }
    }
}

extension FileTransferContext {
    struct DefaultPresent: View {
        let context: FileTransferContext

        var body: some View {
            DefaultModalPresenter {
                FileTransferView(context: context)
            }
        }
    }
}

/// Bridges CatusshModule's shared file-transfer core to UIKit UI.
final class IOSFileTransferUIHandler: FileTransferUIHandler {
    func presentError(_ message: String) {
        UIBridge.presentError(with: message)
    }

    func requiresConfirmation(_ message: String, completion: @escaping (Bool) -> Void) {
        UIBridge.requiresConfirmation(message: message, confirmation: completion)
    }

    func autoOpenInterface(_ context: FileTransferContext) {
        let host = UIHostingController(
            rootView: FileTransferContext.DefaultPresent(context: context)
        )
        host.modalTransitionStyle = .coverVertical
        host.modalPresentationStyle = .formSheet
        host.preferredContentSize = preferredPopOverSize
        UIWindow.shutUpKeyWindow?
            .topMostViewController?
            .present(next: host)
    }

    func downloadCompleted() {
        UIBridge.presentSuccess(with: "Download Completed", subtitle: "Saved to Files")
    }
}
