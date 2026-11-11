//
//  FileTransferContext+Editing.swift
//  CatusshModule
//
//  Reading a remote file as text and writing it back, for the editor. Both go
//  through the session's SFTP connection and a private temporary folder that is
//  removed afterwards.
//

import Foundation

public enum RemoteTextFileError: LocalizedError, Equatable {
    case notConnected
    case tooLarge(bytes: Int64, limit: Int64)
    case notText
    case transfer(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the server."
        case let .tooLarge(bytes, limit):
            let formatter = ByteCountFormatter()
            return "This file is \(formatter.string(fromByteCount: bytes)); files up to \(formatter.string(fromByteCount: limit)) open in the editor. Download it instead."
        case .notText:
            return "This file isn't UTF-8 text, so it can't be edited here. Download it instead."
        case let .transfer(message):
            return message
        }
    }
}

public extension FileTransferContext {
    /// Files larger than this are downloaded rather than opened in the editor.
    static let editableSizeLimit: Int64 = 4 * 1024 * 1024

    /// A folder listing in the order the file lists show it: folders first,
    /// then by name as Finder sorts.
    static func sortedForDisplay(_ list: [RemoteFile]) -> [RemoteFile] {
        // The kind is read once per file, not once per comparison.
        var keyed = list.map { (isDirectory: $0.fstat.isDirectory, file: $0) }
        keyed.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.file.name.localizedStandardCompare(rhs.file.name) == .orderedAscending
        }
        return keyed.map(\.file)
    }

    /// Whether the editor opens `file` (a file within the size limit).
    static func isEditable(_ file: RemoteFile) -> Bool {
        !file.fstat.isDirectory && Int64(truncating: file.fstat.size ?? 0) <= editableSizeLimit
    }

    /// Reads a remote file as UTF-8 text on the context's serial `workerQueue`.
    func readText(at remotePath: String) async throws -> String {
        if !connected && !processConnection {
            processBootstrap()
            _ = await $connected
                .combineLatest($processConnection)
                .timeout(.seconds(30), scheduler: DispatchQueue.main)
                .values
                .first(where: { $0 || !$1 || self.destroyedSession })
        }
        guard connected else { throw RemoteTextFileError.notConnected }
        let folder = try Self.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent)
        nonisolated(unsafe) let shell = shell
        let size: Int64? = await withCheckedContinuation { continuation in
            workerQueue.async {
                continuation.resume(returning: shell.requestFileInfo(at: remotePath)?.size?.int64Value)
            }
        }
        if let size, size > Self.editableSizeLimit {
            throw RemoteTextFileError.tooLarge(bytes: size, limit: Self.editableSizeLimit)
        }
        let succeeded = await runOnWorker {
            shell.requestDownload(fromFileAndWait: remotePath, toLocalPath: local.path) { _, _, _ in
            } withContinuationHandler: {
                true
            }
        }
        guard succeeded else {
            if !shell.isConnected || !shell.isConnectedFileTransfer {
                onMainThread { self.processShutdown() }
            }
            throw RemoteTextFileError.transfer(shell.getLastFileTransferError() ?? "Couldn't read \(remotePath).")
        }
        let data = try Data(contentsOf: local)
        guard Int64(data.count) <= Self.editableSizeLimit else {
            throw RemoteTextFileError.tooLarge(bytes: Int64(data.count), limit: Self.editableSizeLimit)
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw RemoteTextFileError.notText
        }
        return text
    }

    /// Replaces a remote file's contents with `text` (UTF-8) on the context's serial `workerQueue`.
    func writeText(_ text: String, to remotePath: String) async throws {
        guard connected else { throw RemoteTextFileError.notConnected }
        let folder = try Self.makeScratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let remote = URL(fileURLWithPath: remotePath)
        let local = folder.appendingPathComponent(remote.lastPathComponent)
        try Data(text.utf8).write(to: local)
        let directory = remote.deletingLastPathComponent().path
        nonisolated(unsafe) let shell = shell
        let succeeded = await runOnWorker {
            shell.requestUpload(forFileAndWait: local.path, toDirectory: directory) { _, _, _ in
            } withContinuationHandler: {
                true
            }
        }
        guard succeeded else {
            throw RemoteTextFileError.transfer(shell.getLastFileTransferError() ?? "Couldn't save \(remotePath).")
        }
    }

    private static func makeScratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatusshEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func runOnWorker(_ work: @escaping @Sendable () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            workerQueue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
