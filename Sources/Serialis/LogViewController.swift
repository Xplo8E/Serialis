import AppKit
import SerialisCore

/// The table asks for visible rows only. The full log and its row offsets stay on disk.
final class LogViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = LogTableView()
    let scroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Waiting for serial data\nChoose a supported interface in Settings.")
    var onPositionChange: (() -> Void)?
    private(set) var snapshot: SessionSnapshot?
    private(set) var reader: SessionReader?
    private(set) var followsLatest = true
    private var movingProgrammatically = false
    private var scrollObserver: NSObjectProtocol?

    override func loadView() {
        view = NSView()
        let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("number"))
        number.width = 78
        number.minWidth = 78
        number.maxWidth = 78
        let text = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        text.width = 4000
        table.addTableColumn(number)
        table.addTableColumn(text)
        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.copyRows = { [weak self] in self?.copySelection() }
        table.setAccessibilityLabel("Serial log. Select rows to copy or export.")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalToConstant: 320)
        ])
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            guard let self, !self.movingProgrammatically else { return }
            let atBottom = self.scroll.contentView.bounds.maxY >= self.table.bounds.height - 24
            self.followsLatest = atBottom && self.table.selectedRowIndexes.isEmpty
            self.onPositionChange?()
        }
    }

    func show(_ next: SessionSnapshot, follow: Bool? = nil) throws {
        _ = view // Load lazily on macOS 13 as well.
        let changedSession = snapshot?.directory != next.directory
        if changedSession {
            reader = try SessionReader(directory: next.directory)
            table.deselectAll(nil)
            followsLatest = true
        }
        if let follow { followsLatest = follow }
        let shouldFollow = followsLatest
        let oldCount = snapshot?.rowCount ?? 0
        snapshot = next
        emptyLabel.stringValue = "No serial data in this session yet.\nChoose a supported interface in Settings."
        emptyLabel.isHidden = next.rowCount > 0
        movingProgrammatically = true
        if changedSession {
            table.reloadData()
        } else {
            table.noteNumberOfRowsChanged()
            // The previously unfinished row may have received more bytes.
            if oldCount > 0, oldCount <= next.rowCount {
                table.reloadData(forRowIndexes: IndexSet(integer: Int(oldCount - 1)),
                                 columnIndexes: IndexSet(integersIn: 0..<2))
            }
        }
        if shouldFollow, next.rowCount > 0 { table.scrollRowToVisible(Int(next.rowCount - 1)) }
        movingProgrammatically = false
        followsLatest = shouldFollow
    }

    func clear(message: String) {
        _ = view
        snapshot = nil
        reader = nil
        table.reloadData()
        emptyLabel.stringValue = message
        emptyLabel.isHidden = false
    }

    func jumpToLatest() {
        table.deselectAll(nil)
        followsLatest = true
        movingProgrammatically = true
        if let snapshot, snapshot.rowCount > 0 { table.scrollRowToVisible(Int(snapshot.rowCount - 1)) }
        movingProgrammatically = false
        onPositionChange?()
    }

    func reveal(_ match: Range<UInt64>) throws {
        guard let snapshot, let reader else { return }
        let row = Int(try reader.row(containing: match.lowerBound, snapshot: snapshot))
        followsLatest = false
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        onPositionChange?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Int(snapshot?.rowCount ?? 0) }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, let reader, let snapshot else { return nil }
        let field = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = column.identifier
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byClipping
        field.maximumNumberOfLines = 1
        if column.identifier.rawValue == "number" {
            field.stringValue = String(row + 1)
            field.alignment = .right
            field.textColor = .tertiaryLabelColor
        } else {
            do {
                let data = try reader.readRow(UInt64(row), snapshot: snapshot).data
                // Rendering is lossy for non-UTF-8 data. Copy/export always read the original bytes.
                field.stringValue = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                    .replacingOccurrences(of: "\t", with: "    ")
                    .replacingOccurrences(of: "\0", with: "␀")
                field.textColor = .labelColor
                let width = min(160000, max(4000, CGFloat(field.stringValue.utf16.count) * 8))
                if width > column.width { column.width = width }
            } catch {
                field.stringValue = "Read error: \(error.localizedDescription)"
                field.textColor = .systemRed
            }
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !table.selectedRowIndexes.isEmpty { followsLatest = false }
        onPositionChange?()
    }

    private func selectedByteRanges() throws -> [Range<UInt64>] {
        guard let reader, let snapshot else { return [] }
        return try table.selectedRowIndexes.rangeView.map { rows in
            let first = try reader.readRow(UInt64(rows.lowerBound), snapshot: snapshot)
            let last = try reader.readRow(UInt64(rows.upperBound - 1), snapshot: snapshot)
            return first.offset..<(last.offset + UInt64(last.data.count))
        }
    }

    @objc func copySelection() {
        do {
            let ranges = try selectedByteRanges()
            guard !ranges.isEmpty, let reader else { return }
            let size = ranges.reduce(UInt64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
            if size > 16 * 1024 * 1024 {
                let alert = NSAlert()
                alert.messageText = "Export this large selection?"
                alert.informativeText = "Copying more than 16 MiB would increase memory use. Export saves all selected bytes to a file."
                alert.addButton(withTitle: "Export Selection")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { exportSelection(nil) }
                return
            }
            var data = Data()
            for range in ranges { data.append(try reader.readBytes(in: range)) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType("public.data"))
        } catch { NSAlert(error: error).runModal() }
    }

    @objc func exportSelection(_ sender: Any?) {
        do {
            let ranges = try selectedByteRanges()
            guard !ranges.isEmpty, let reader else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "serialis-selection.log"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // Streaming also keeps multi-gigabyte selections out of memory.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let file = try FileHandle(forWritingTo: url)
                    defer { try? file.close() }
                    for range in ranges {
                        var offset = range.lowerBound
                        while offset < range.upperBound {
                            let end = min(offset + 65536, range.upperBound)
                            try file.write(contentsOf: reader.readBytes(in: offset..<end))
                            offset = end
                        }
                    }
                    try file.synchronize()
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } catch { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
            }
        } catch { NSAlert(error: error).runModal() }
    }

    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
}

final class LogTableView: NSTableView {
    var copyRows: (() -> Void)?
    @objc func copy(_ sender: Any?) { copyRows?() }
}
