//
//  FileTable.swift
//  catussh (macOS)
//
//  The file list's UIKit half: the table, its text view and its cell, drawn to
//  the measurements of the SwiftUI rows elsewhere. Split out of FileTransferPage.
//

import CatusshModule
import SwiftUI

/// The page's header and the cells share these, so the columns line up.
enum FileColumns {
    static let size: CGFloat = 90
    static let gap: CGFloat = RX.Space.s4
    static let modified: CGFloat = 150
    static let permissions: CGFloat = 110
    static let owner: CGFloat = 70
}

/// A folder's rows in a UIKit table. Only the rows on screen exist, however long
/// the folder is, and a redraw of the page costs the table nothing unless the
/// list or the selection changed.
struct FileTable: UIViewRepresentable {
    typealias File = FileTransferContext.RemoteFile

    let files: [File]
    /// The folder `files` came from once `revision` has moved on.
    let folder: String
    let revision: Int
    let selection: File?
    let select: (File) -> Void
    let open: (File) -> Void
    let menu: (File) -> UIMenu

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = RX.denseRowHeight
        table.estimatedRowHeight = RX.denseRowHeight
        table.sectionHeaderTopPadding = 0
        // Clicks and hover are the rows' own.
        table.allowsSelection = false
        table.allowsFocus = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.register(FileCell.self, forCellReuseIdentifier: Coordinator.reuse)
        return table
    }

    // Nothing is done to the table here. Moving it re-tests what the pointer is
    // over, and that test reads the SwiftUI graph this update is in the middle
    // of: entering a folder with the pointer over the list never returned.
    func updateUIView(_ table: UITableView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.enabled = context.environment.isEnabled
        coordinator.schedule(table)
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        static var reuse: String { "file" }
        var parent: FileTable
        var enabled = true
        /// What the table shows, which is `parent`'s once `apply` has run.
        private var rows: [File]
        private var shownRevision: Int
        private var shownSelection: File?
        private var shownFolder: String?
        private var scheduled = false

        init(_ parent: FileTable) {
            self.parent = parent
            rows = parent.files
            shownRevision = parent.revision
            shownSelection = parent.selection
        }

        func schedule(_ table: UITableView) {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self, weak table] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduled = false
                    if let table { self.apply(to: table) }
                }
            }
        }

        private func apply(to table: UITableView) {
            if table.isUserInteractionEnabled != enabled { table.isUserInteractionEnabled = enabled }
            if shownRevision != parent.revision {
                // Another folder starts at its top and fades in; a reload or the
                // filter changes the rows in place.
                let entered = shownFolder != parent.folder && shownFolder != nil
                rows = parent.files
                if entered, !UIAccessibility.isReduceMotionEnabled {
                    UIView.transition(with: table, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                        table.reloadData()
                        table.contentOffset = .zero
                    }
                } else {
                    table.reloadData()
                    if entered { table.contentOffset = .zero }
                }
                shownRevision = parent.revision
                shownFolder = parent.folder
            } else if shownSelection != parent.selection {
                for case let cell as FileCell in table.visibleCells {
                    cell.setChosen(cell.file == parent.selection, animated: true)
                }
            }
            shownSelection = parent.selection
        }

        func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
            rows.count
        }

        func tableView(_ table: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = table.dequeueReusableCell(withIdentifier: Self.reuse, for: indexPath)
            guard let cell = cell as? FileCell else { return cell }
            let file = rows[indexPath.row]
            cell.show(file, chosen: file == parent.selection)
            cell.onClick = { [weak self] in self?.parent.select(file) }
            cell.onDoubleClick = { [weak self] in self?.parent.open(file) }
            return cell
        }

        func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint) -> UIContextMenuConfiguration? {
            guard rows.indices.contains(indexPath.row) else { return nil }
            let file = rows[indexPath.row]
            let menu = parent.menu
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu(file) }
        }
    }
}

/// A line of text drawn as SwiftUI's `Text` draws it. A label pulls the letters
/// of a truncated name together and so cuts it a character later, and it
/// spaces the digits of a size a fraction of a point apart.
private final class FileCellText: UIView {
    var text = "" { didSet { if text != oldValue { setNeedsDisplay() } } }
    var textColor = UIColor.label { didSet { if textColor != oldValue { setNeedsDisplay() } } }
    var font = UIFont.systemFont(ofSize: 13)
    var trailing = false

    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        style.allowsDefaultTighteningForTruncation = false
        return style
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor, .paragraphStyle: Self.paragraph,
        ]
        let string = text as NSString
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let scale = max(traitCollection.displayScale, 1)
        let fitted = string.boundingRect(
            with: CGSize(width: bounds.width, height: .greatestFiniteMagnitude),
            options: options, attributes: attributes, context: nil
        )
        let width = min(bounds.width, (fitted.width * scale).rounded(.up) / scale)
        let height = (fitted.height * scale).rounded(.up) / scale
        let y = ((bounds.height - height) / 2 * scale).rounded() / scale
        string.draw(
            with: CGRect(x: trailing ? bounds.width - width : 0, y: y, width: trailing ? width : bounds.width, height: height),
            options: options, attributes: attributes, context: nil
        )
    }
}

/// One file: symbol and name, size, date, permissions, owner. Drawn with UIKit
/// views to the measurements of the SwiftUI rows elsewhere in the app.
private final class FileCell: UITableViewCell {
    private(set) var file: FileTransferContext.RemoteFile?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var isChosen = false
    private var isHovered = false

    private let row = UIView()
    private let icon = UIImageView()
    private let name = FileCellText()
    private let size = FileCellText()
    private let modified = UILabel()
    private let permissions = UILabel()
    private let owner = UILabel()

    private static let ink = UIColor(Color.rxInk)
    private static let inkSecondary = UIColor(Color.rxInkSecondary)
    private static let accent = UIColor(Color.rxAccent)
    private static let rowSelected = UIColor(Color.rxRowSelected)
    private static let rowHover = UIColor(Color.rxRowHover)
    private static let body = UIFont.systemFont(ofSize: 13)
    private static let digits = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let code = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let symbol = UIImage.SymbolConfiguration(font: .systemFont(ofSize: 14))
    private static let symbols: [String: UIImage] = ["folder", "link", "doc"].reduce(into: [:]) {
        $0[$1] = UIImage(systemName: $1, withConfiguration: symbol)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundConfiguration = .clear()
        focusEffect = nil

        row.layer.cornerRadius = RX.Radius.lg
        row.layer.cornerCurve = .continuous
        contentView.addSubview(row)

        icon.contentMode = .center
        name.font = Self.body
        name.textColor = Self.ink
        size.font = Self.digits
        size.trailing = true
        modified.font = Self.body
        modified.textColor = Self.inkSecondary
        permissions.font = Self.code
        permissions.textColor = Self.inkSecondary
        owner.font = Self.digits
        owner.textColor = Self.inkSecondary
        for view in [icon, name, size, modified, permissions, owner] { row.addSubview(view) }

        let click = UITapGestureRecognizer(target: self, action: #selector(clicked))
        let doubleClick = UITapGestureRecognizer(target: self, action: #selector(doubleClicked))
        doubleClick.numberOfTapsRequired = 2
        // The first click selects at once; it doesn't wait to see whether a
        // second follows.
        click.delegate = self
        doubleClick.delegate = self
        contentView.addGestureRecognizer(click)
        contentView.addGestureRecognizer(doubleClick)
        contentView.addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ file: FileTransferContext.RemoteFile, chosen: Bool) {
        self.file = file
        let stat = file.fstat
        let isDirectory = stat.isDirectory
        icon.image = Self.symbols[isDirectory ? "folder" : (stat.isLink ? "link" : "doc")]
        icon.tintColor = isDirectory ? Self.accent : Self.inkSecondary
        name.text = file.name
        size.text = isDirectory ? "—" : RXFormat.bytesString(Double(truncating: stat.size ?? 0))
        size.textColor = isDirectory ? Self.inkSecondary : Self.ink
        modified.text = stat.modificationDate.map { Self.dateFormatter.string(from: $0) } ?? "—"
        permissions.text = stat.permissionDescription
        // A uid is an id, not a quantity: 1000, never "1,000".
        owner.text = String(stat.ownerUID)
        isHovered = false
        isChosen = chosen
        refreshBackground(animated: false)
        setNeedsLayout()
    }

    func setChosen(_ chosen: Bool, animated: Bool) {
        guard chosen != isChosen else { return }
        isChosen = chosen
        refreshBackground(animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        row.frame = contentView.bounds
        let height = row.bounds.height
        var trailing = row.bounds.width - RX.Space.s3
        func place(_ view: UIView, width: CGFloat) {
            trailing -= width
            view.frame = CGRect(x: trailing, y: 0, width: width, height: height)
        }
        place(owner, width: FileColumns.owner)
        place(permissions, width: FileColumns.permissions)
        place(modified, width: FileColumns.modified)
        trailing -= FileColumns.gap
        place(size, width: FileColumns.size)
        icon.frame = CGRect(x: RX.Space.s3, y: 0, width: 18, height: height)
        let nameLeading = icon.frame.maxX + RX.Space.s2
        name.frame = CGRect(x: nameLeading, y: 0, width: max(0, trailing - nameLeading), height: height)
    }

    private func refreshBackground(animated: Bool) {
        let color = isChosen ? Self.rowSelected : (isHovered ? Self.rowHover : .clear)
        guard animated else { return row.backgroundColor = color }
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
            self.row.backgroundColor = color
        }
    }

    @objc private func clicked() { onClick?() }
    @objc private func doubleClicked() { onDoubleClick?() }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        let hovering = recognizer.state == .began || recognizer.state == .changed
        guard hovering != isHovered else { return }
        isHovered = hovering
        refreshBackground(animated: true)
    }

    override func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }
}
