import AppKit
import SerialisCore

final class SessionInspectorView: NSView {
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }

    private let titleLabel = ConsoleTheme.label("Session inspector", size: 13, weight: .semibold)
    private let closeButton = ConsoleButton("", symbol: "xmark")
    private let scrollView = NSScrollView()
    private let contentView = FlippedView()

    private let sessionSection = SectionBlock(title: "Session")
    private let startedRow = InspectorRow(key: "Started")
    private let endedRow = InspectorRow(key: "Ended")
    private let bytesRow = InspectorRow(key: "Bytes")
    private let rowsRow = InspectorRow(key: "Rows")

    private let interfaceSection = SectionBlock(title: "Interface")
    private let productRow = InspectorRow(key: "Product")
    private let pathRow = InspectorRow(key: "Path")
    private let serialRow = InspectorRow(key: "Serial")

    private let filesSection = SectionBlock(title: "Files")
    private let rawButton = InspectorLinkButton(title: "Reveal capture.raw")
    private let metadataButton = InspectorLinkButton(title: "Reveal metadata.json")
    private let indexButton = InspectorLinkButton(title: "Reveal rows.idx")

    private let eventsSection = SectionBlock(title: "Events")
    private var eventLabels: [NSTextField] = []

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 280, height: 420)
    }

    func update(_ snapshot: SessionSnapshot) {
        startedRow.value = dateFormatter.string(from: snapshot.metadata.startedAt)
        endedRow.value = snapshot.metadata.endedAt.map { dateFormatter.string(from: $0) } ?? ""
        endedRow.isHidden = snapshot.metadata.endedAt == nil
        bytesRow.value = byteText(snapshot.byteCount)
        rowsRow.value = decimalText(snapshot.rowCount)

        if let segment = snapshot.metadata.segments.last {
            productRow.value = segment.device.product.isEmpty ? "Serial interface" : segment.device.product
            pathRow.value = segment.device.path
            serialRow.value = segment.device.serialNumber.isEmpty ? "Unknown" : segment.device.serialNumber
        } else {
            productRow.value = "No interface recorded"
            pathRow.value = "-"
            serialRow.value = "-"
        }

        rawButton.fileURL = snapshot.directory.appendingPathComponent("capture.raw")
        metadataButton.fileURL = snapshot.directory.appendingPathComponent("metadata.json")
        indexButton.fileURL = snapshot.directory.appendingPathComponent("rows.idx")

        updateEvents(Array(snapshot.metadata.events.suffix(10)))
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        ConsoleTheme.background.setFill(); bounds.fill()
        ConsoleTheme.border.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override func layout() {
        super.layout()

        let width = bounds.width > 0 ? bounds.width : 280
        titleLabel.frame = NSRect(x: 16, y: 12, width: width - 58, height: 18)
        closeButton.frame = NSRect(x: width - 36, y: 10, width: 24, height: 24)
        scrollView.frame = NSRect(x: 0, y: 46, width: width, height: max(0, bounds.height - 46))
        layoutContent(width: width)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func setup() {
        wantsLayer = true
        addSubview(titleLabel)
        addSubview(closeButton)
        addSubview(scrollView)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setAccessibilityLabel("Close session inspector")

        scrollView.documentView = contentView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        for view in [
            sessionSection, startedRow, endedRow, bytesRow, rowsRow,
            interfaceSection, productRow, pathRow, serialRow,
            filesSection, rawButton, metadataButton, indexButton,
            eventsSection
        ] {
            contentView.addSubview(view)
        }

        for button in [rawButton, metadataButton, indexButton] {
            button.target = self
            button.action = #selector(revealFile(_:))
        }

        updateEvents([])
        applyColors()
    }

    private func updateEvents(_ events: [SessionEvent]) {
        let texts: [String]
        if events.isEmpty {
            texts = ["No events recorded"]
        } else {
            texts = events.map { "\(timeFormatter.string(from: $0.date))  \($0.message)" }
        }

        while eventLabels.count < texts.count {
            let label = ConsoleTheme.label("", size: 11, color: ConsoleTheme.secondary)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            eventLabels.append(label)
            contentView.addSubview(label)
        }

        for (index, label) in eventLabels.enumerated() {
            label.isHidden = index >= texts.count
            if index < texts.count {
                label.stringValue = texts[index]
            }
        }
    }

    private func layoutContent(width: CGFloat) {
        let contentWidth = max(0, width - 32)
        var y: CGFloat = 16

        func placeSection(_ section: SectionBlock) {
            section.frame = NSRect(x: 16, y: y, width: contentWidth, height: 16)
            y += 22
        }

        func placeRows(_ rows: [InspectorRow]) {
            for row in rows where !row.isHidden {
                row.frame = NSRect(x: 16, y: y, width: contentWidth, height: 32)
                y += 34
            }
        }

        func placeButtons(_ buttons: [InspectorLinkButton]) {
            for button in buttons {
                button.frame = NSRect(x: 16, y: y, width: contentWidth, height: 22)
                y += 28
            }
        }

        placeSection(sessionSection)
        placeRows([startedRow, endedRow, bytesRow, rowsRow])

        y += 6
        placeSection(interfaceSection)
        placeRows([productRow, pathRow, serialRow])

        y += 6
        placeSection(filesSection)
        placeButtons([rawButton, metadataButton, indexButton])

        y += 6
        placeSection(eventsSection)
        for label in eventLabels where !label.isHidden {
            let size = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: contentWidth, height: 1000)) ?? NSSize(width: contentWidth, height: 16)
            label.frame = NSRect(x: 16, y: y, width: contentWidth, height: max(16, size.height))
            y += max(22, size.height + 8)
        }

        contentView.frame = NSRect(x: 0, y: 0, width: width, height: y + 16)
    }

    private func applyColors() {
        needsDisplay = true
        closeButton.needsDisplay = true
        for view in contentView.subviews {
            view.needsDisplay = true
        }
    }

    private func byteText(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private func decimalText(_ value: UInt64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func revealFile(_ sender: InspectorLinkButton) {
        guard let url = sender.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SectionBlock: NSView {
    private let label: NSTextField

    init(title: String) {
        label = ConsoleTheme.label(title, size: 11, weight: .semibold, color: ConsoleTheme.secondary)
        super.init(frame: .zero)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(title:)")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        label.frame = bounds
    }
}

private final class InspectorRow: NSView {
    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    private let keyLabel: NSTextField
    private let valueLabel = ConsoleTheme.label("", size: 12, color: ConsoleTheme.text)

    init(key: String) {
        keyLabel = ConsoleTheme.label(key, size: 10, color: ConsoleTheme.tertiary)
        super.init(frame: .zero)
        addSubview(keyLabel)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(key:)")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        keyLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 12)
        valueLabel.frame = NSRect(x: 0, y: 15, width: bounds.width, height: 16)
    }
}

private final class InspectorLinkButton: NSButton {
    var fileURL: URL?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        font = .systemFont(ofSize: 11)
        isBordered = false
        setButtonType(.momentaryPushIn)
        alignment = .left
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(title:)")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 11),
            .foregroundColor: ConsoleTheme.accent
        ]
        let textRect = NSRect(x: 0, y: 3, width: bounds.width, height: 16)
        (title as NSString).draw(in: textRect, withAttributes: attributes)
    }
}
