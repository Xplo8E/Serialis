import AppKit
import SerialisCore

private final class LogScrollDocument: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { } // This container needs no full-document bitmap.
}

/// Capture stays on disk. The canvas lays out only a bounded window of wrapped text.
final class LogViewController: NSViewController {
    let canvas = WrappedLogView()
    let scroll = NSScrollView()
    private let emptyView = NSStackView()
    private let emptyTitle = ConsoleTheme.label("Waiting for serial data", size: 13, weight: .medium)
    private let emptySubtitle = ConsoleTheme.label("Choose a supported interface in Settings.", color: ConsoleTheme.secondary)
    var onPositionChange: (() -> Void)?
    var highlightedQuery: String? { didSet { canvas.query = highlightedQuery } }
    private(set) var snapshot: SessionSnapshot?
    private(set) var reader: SessionReader?
    var followsLatest: Bool { canvas.followsLatest }

    override func loadView() {
        view = ConsolePanel()
        // The empty document supplies the scroll range. Only the viewport-sized
        // canvas draws, avoiding a backing bitmap as tall as the full session.
        let document = LogScrollDocument()
        document.wantsLayer = true
        document.addSubview(canvas)
        scroll.documentView = document
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = ConsoleTheme.background
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        emptyView.orientation = .vertical
        emptyView.alignment = .centerX
        emptyView.spacing = 6
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        icon.contentTintColor = ConsoleTheme.tertiary
        emptyView.addArrangedSubview(icon)
        emptyView.addArrangedSubview(emptyTitle)
        emptyView.addArrangedSubview(emptySubtitle)
        view.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        canvas.onPositionChange = { [weak self] in self?.onPositionChange?() }
        canvas.onCopy = { [weak self] in self?.copySelection() }
        canvas.onError = { [weak self] error in
            self?.emptyTitle.stringValue = "Could not read this session"
            self?.emptySubtitle.stringValue = error.localizedDescription
            self?.emptyView.isHidden = false
        }
        canvas.observeScrolling()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        canvas.viewportResized()
    }

    func show(_ next: SessionSnapshot, follow: Bool? = nil) throws {
        _ = view
        if snapshot?.directory != next.directory { reader = try SessionReader(directory: next.directory) }
        snapshot = next
        emptyTitle.stringValue = "No serial data in this session yet."
        emptySubtitle.stringValue = "Choose a supported interface in Settings."
        emptyView.isHidden = next.rowCount > 0
        if let reader { try canvas.show(next, reader: reader, follow: follow) }
    }

    func clear(message: String) {
        _ = view
        snapshot = nil; reader = nil
        canvas.clear()
        emptyTitle.stringValue = "Waiting for serial data"
        emptySubtitle.stringValue = message
        emptyView.isHidden = false
    }
    func jumpToLatest() { canvas.jumpToLatest() }
    func reveal(_ match: Range<UInt64>) throws { try canvas.reveal(match) }
    private func selectedByteRanges() throws -> [Range<UInt64>] {
        guard let range = try canvas.selectedByteRange(), !range.isEmpty else { return [] }
        return [range]
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

}
