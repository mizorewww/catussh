//
//  FileTable.swift
//  catussh (macOS)
//
//  Native SwiftUI virtualized file list for macOS.
//

import CatusshModule
import SwiftUI

enum FileColumns {
    static let size: CGFloat = 90
    static let gap: CGFloat = RX.Space.s4
    static let modified: CGFloat = 150
    static let permissions: CGFloat = 110
    static let owner: CGFloat = 70

    @MainActor static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

struct FileTable<MenuContent: View>: View {
    typealias File = FileTransferContext.RemoteFile

    let files: [File]
    let folder: String
    let revision: Int
    let selection: File?
    let select: (File) -> Void
    let open: (File) -> Void
    @ViewBuilder let menu: (File) -> MenuContent

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(files) { file in
                        FileRowView(
                            file: file,
                            selected: file == selection,
                            select: { select(file) },
                            open: { open(file) },
                            menu: { menu(file) }
                        )
                        .id(file.id)
                    }
                }
            }
            .onChange(of: folder) { _ in
                if let first = files.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }
}

private struct FileRowView<MenuContent: View>: View {
    let file: FileTransferContext.RemoteFile
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var hovered = false

    var body: some View {
        let stat = file.fstat
        let isDir = stat.isDirectory
        HStack(spacing: 0) {
            HStack(spacing: RX.Space.s2) {
                Image(systemName: isDir ? "folder" : (stat.isLink ? "link" : "doc"))
                    .font(.system(size: 14))
                    .foregroundStyle(isDir ? Color.rxAccent : Color.rxInkSecondary)
                    .frame(width: 18)
                Text(file.name)
                    .font(.rxBody)
                    .foregroundStyle(.rxInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(isDir ? "—" : RXFormat.bytesString(Double(truncating: stat.size ?? 0)))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(isDir ? Color.rxInkSecondary : Color.rxInk)
                .lineLimit(1)
                .frame(width: FileColumns.size, alignment: .trailing)

            Color.clear.frame(width: FileColumns.gap, height: 1)

            Text(stat.modificationDate.map { FileColumns.dateFormatter.string(from: $0) } ?? "—")
                .font(.rxBody)
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
                .frame(width: FileColumns.modified, alignment: .leading)

            Text(stat.permissionDescription)
                .font(.rxCode)
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
                .frame(width: FileColumns.permissions, alignment: .leading)

            Text(stat.ownerUID == 0 ? "root" : String(stat.ownerUID))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.rxInkSecondary)
                .lineLimit(1)
                .frame(width: FileColumns.owner, alignment: .leading)
        }
        .padding(.horizontal, RX.Space.s3)
        .frame(height: RX.denseRowHeight)
        .rxRowBackground(selected: selected, hovered: hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                select()
                open()
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                select()
            }
        )
        .contextMenu {
            menu()
        }
    }
}
