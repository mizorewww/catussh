//
//  DataBackupSettings.swift
//  mCatussh
//
//  Backup export and import, and the OpenSSH config importer, under
//  Settings › General › Data; the importer also sits in the Servers menu.
//  Files come and go through the Files app's pickers.
//

import CatusshModule
import SwiftUI
import UniformTypeIdentifiers

/// A backup archive as a file to save.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Where an OpenSSH config comes from: the whole .ssh folder, so the keys it
/// names load too, or the config file alone.
enum SSHConfigSource: Identifiable {
    case folder
    case file

    var id: Self { self }

    var contentTypes: [UTType] {
        switch self {
        case .folder: return [.folder]
        case .file: return [.item]
        }
    }
}

enum DataImport {
    /// Imports the config at `url` (a .ssh folder or a config file) and
    /// says what came in.
    @MainActor
    static func importSSHConfig(from url: URL, source: SSHConfigSource) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let configURL = source == .folder ? url.appendingPathComponent("config") : url
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            UIBridge.presentError(with: source == .folder
                ? "There is no readable config file in \(url.lastPathComponent)."
                : "Could not read \(url.lastPathComponent) as UTF-8 text.")
            return
        }
        let keys = source == .folder ? url : nil
        let result = CatusshStore.shared.importOpenSSHConfig(
            text,
            baseDirectory: configURL.deletingLastPathComponent(),
            keyDirectory: keys
        )
        UIBridge.presentSuccess(
            with: "Imported \(result.importedServers) servers and \(result.importedIdentities) identities",
            subtitle: source == .file && result.importedIdentities > 0
                ? "Keys load only when you import the whole .ssh folder."
                : nil
        )
    }

    @MainActor
    static func importBackup(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let result = try CatusshStore.shared.importBackupData(data)
            UIBridge.presentSuccess(
                with: "Backup imported",
                subtitle: "\(result.machines) servers, \(result.identities) identities, \(result.snippets) snippets, and \(result.forwards) port forwards."
            )
        } catch {
            UIBridge.presentError(with: "Could not import backup: \(error.localizedDescription)")
        }
    }
}

extension View {
    /// Presents the Files picker for an OpenSSH config while `source` is set.
    func sshConfigImporter(_ source: Binding<SSHConfigSource?>) -> some View {
        modifier(SSHConfigImporter(source: source))
    }
}

private struct SSHConfigImporter: ViewModifier {
    @Binding var source: SSHConfigSource?

    func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: Binding(get: { source != nil }, set: { if !$0 { source = nil } }),
            allowedContentTypes: source?.contentTypes ?? [.item]
        ) { result in
            let picked = source ?? .file
            source = nil
            switch result {
            case let .success(url):
                DataImport.importSSHConfig(from: url, source: picked)
            case let .failure(error):
                UIBridge.presentError(with: error.localizedDescription)
            }
        }
    }
}

/// The ssh_config import entries for a menu.
struct SSHConfigImportMenuItems: View {
    @Binding var source: SSHConfigSource?

    var body: some View {
        Button {
            source = .folder
        } label: {
            Label("Import .ssh Folder…", systemImage: "folder.badge.gearshape")
        }
        Button {
            source = .file
        } label: {
            Label("Import ssh_config File…", systemImage: "square.and.arrow.down")
        }
    }
}

/// Settings rows: export and import a backup; import an OpenSSH config.
struct DataBackupRows: View {
    var body: some View {
        RXDividedStack {
            BackupRow()
            SSHConfigRow()
        }
    }
}

private struct BackupRow: View {
    @State private var exportDocument: BackupDocument?
    @State private var importing = false

    var body: some View {
        RXFormRow(
            "Backup archive",
            description: "Export or import all saved servers, identities, snippets, port forwards, and folders as a JSON backup file. It holds passwords and keys unencrypted."
        ) {
            Menu {
                Button {
                    export()
                } label: {
                    Label("Export Backup…", systemImage: "square.and.arrow.up")
                }
                Button {
                    importing = true
                } label: {
                    Label("Import Backup…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Text("Backup")
            }
            .buttonStyle(.rx(size: .small))
            .fixedSize()
        }
        .fileExporter(
            isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
            document: exportDocument,
            contentType: .json,
            defaultFilename: "catussh-backup.json"
        ) { result in
            exportDocument = nil
            switch result {
            case let .success(url):
                UIBridge.presentSuccess(with: "Exported backup to \(url.lastPathComponent)")
            case let .failure(error):
                UIBridge.presentError(with: "Could not export backup: \(error.localizedDescription)")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                DataImport.importBackup(from: url)
            case let .failure(error):
                UIBridge.presentError(with: error.localizedDescription)
            }
        }
    }

    private func export() {
        do {
            exportDocument = try BackupDocument(data: CatusshStore.shared.exportBackupData())
        } catch {
            UIBridge.presentError(with: "Could not export backup: \(error.localizedDescription)")
        }
    }
}

private struct SSHConfigRow: View {
    @State private var source: SSHConfigSource?

    var body: some View {
        RXFormRow(
            "OpenSSH config",
            description: "Import Host entries, IdentityFile keys, and ProxyJump links from an OpenSSH config. Pick the whole .ssh folder so the keys it names load too."
        ) {
            Menu {
                SSHConfigImportMenuItems(source: $source)
            } label: {
                Text("Import")
            }
            .buttonStyle(.rx(size: .small))
            .fixedSize()
        }
        .sshConfigImporter($source)
    }
}
