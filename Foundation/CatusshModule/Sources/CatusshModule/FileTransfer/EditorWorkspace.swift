//
//  EditorWorkspace.swift
//  CatusshModule
//
//  Shared remote file editor documents, workspace, and center across macOS and iOS.
//

import CatusshEditor
import Combine
import Foundation
import SwiftUI

/// Where the caret is. Apart from the document, so moving the caret redraws
/// the status line and nothing else.
@MainActor
public final class EditorCaretPosition: ObservableObject {
    @Published public var value = EditorCaret(line: 1, column: 1)
    public init() {}
}

/// One remote text file open in the editor.
@MainActor
public final class EditorDocument: ObservableObject, Identifiable {
    public enum Phase: Equatable {
        case loading
        case editing
        case failed(String)
    }

    public nonisolated let id = UUID()
    public let path: String
    private let context: FileTransferContext

    @Published public private(set) var phase = Phase.loading
    @Published public private(set) var isEdited = false
    @Published public private(set) var saving = false
    @Published public var language = EditorLanguage.plain
    public let caret = EditorCaretPosition()

    /// Not published: the editor view holds what is typed, and publishing every
    /// keystroke would redraw the page around it.
    public var text = "" {
        didSet {
            let edited = text != savedText
            if edited != isEdited { isEdited = edited }
        }
    }

    private var savedText = ""

    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }

    public init(path: String, context: FileTransferContext) {
        self.path = path
        self.context = context
        load()
    }

    #if DEBUG
        /// A file that is already loaded, for the editor preview.
        public init(path: String, context: FileTransferContext, preview: String) {
            self.path = path
            self.context = context
            savedText = preview
            text = preview
            language = EditorLanguage.detect(fileName: (path as NSString).lastPathComponent, firstLine: String(preview.prefix { $0 != "\n" }))
            phase = .editing
        }
    #endif

    /// Reads the file from the server, replacing what the editor shows.
    public func load() {
        phase = .loading
        Task {
            do {
                try await waitForConnection()
                nonisolated(unsafe) let context = context
                let loaded = try await context.readText(at: path)
                savedText = loaded
                text = loaded
                let firstLine = loaded.prefix { $0 != "\n" }
                language = EditorLanguage.detect(fileName: name, firstLine: String(firstLine))
                phase = .editing
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    public func save(onError: (@MainActor (String) -> Void)? = nil) {
        guard phase == .editing, isEdited, !saving else { return }
        let snapshot = text
        saving = true
        Task {
            defer { saving = false }
            do {
                nonisolated(unsafe) let context = context
                try await context.writeText(snapshot, to: path)
                savedText = snapshot
                isEdited = text != snapshot
                if context.currentUrl.path == folder { context.loadCurrentFileList() }
            } catch {
                let message = "Couldn't save \(name). \(error.localizedDescription)"
                if let onError {
                    onError(message)
                } else {
                    FileTransferInterface.uiHandler.presentError(message)
                }
            }
        }
    }

    private func waitForConnection() async throws {
        nonisolated(unsafe) let context = context
        await Self.waitForConnection(of: context)
    }

    private nonisolated static func waitForConnection(of context: FileTransferContext) async {
        _ = await context.$connected
            .combineLatest(context.$processConnection)
            .timeout(.seconds(30), scheduler: DispatchQueue.main)
            .values
            .first(where: { $0 || !$1 || context.destroyedSession })
    }
}

/// A server's open files and the one in front.
@MainActor
public final class EditorWorkspace: ObservableObject, Identifiable {
    public let context: FileTransferContext
    public nonisolated let id: UUID

    @Published public private(set) var documents: [EditorDocument] = []
    @Published public var selection: EditorDocument.ID?
    private var observers: [EditorDocument.ID: AnyCancellable] = [:]

    public init(context: FileTransferContext) {
        self.context = context
        id = context.id
    }

    public var current: EditorDocument? {
        documents.first { $0.id == selection }
    }

    public var hasUnsavedChanges: Bool {
        documents.contains(where: \.isEdited)
    }

    /// Shows the file, opening it if it isn't open yet.
    public func open(path: String) {
        if let existing = documents.first(where: { $0.path == path }) {
            selection = existing.id
            return
        }
        add(EditorDocument(path: path, context: context))
    }

    public func add(_ document: EditorDocument) {
        observers[document.id] = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        documents.append(document)
        selection = document.id
    }

    public func remove(_ document: EditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        observers[document.id] = nil
        if selection == document.id {
            selection = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
        }
    }

    public func moveDocument(fromID: EditorDocument.ID, toID: EditorDocument.ID) {
        guard fromID != toID,
              let fromIndex = documents.firstIndex(where: { $0.id == fromID }),
              let toIndex = documents.firstIndex(where: { $0.id == toID })
        else { return }
        var updated = documents
        let item = updated.remove(at: fromIndex)
        updated.insert(item, at: toIndex)
        documents = updated
    }

    #if DEBUG
        public func addPreview(path: String, text: String) {
            add(EditorDocument(path: path, context: context, preview: text))
        }
    #endif
}

/// Every server's editor, by the id of its SFTP session.
@MainActor
public final class EditorCenter: ObservableObject {
    public static let shared = EditorCenter()

    @Published public private(set) var workspaces: [EditorWorkspace] = []
    private var cancellable: AnyCancellable?

    private init() {
        cancellable = FileTransferManager.shared.$transfers.sink { [weak self] transfers in
            guard let self else { return }
            let alive = Set(transfers.map(\.id))
            if self.workspaces.contains(where: { !alive.contains($0.id) }) {
                self.workspaces.removeAll { !alive.contains($0.id) }
            }
        }
    }

    public func workspace(for context: FileTransferContext) -> EditorWorkspace {
        if let existing = workspaces.first(where: { $0.id == context.id }) { return existing }
        let workspace = EditorWorkspace(context: context)
        workspaces.append(workspace)
        return workspace
    }

    public func end(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
    }
}
