import AppKit
import SerialisCore

final class InterfacePickerView: NSView {
    var onSelect: ((SerialDevice) -> Void)?
    var onRefresh: (() -> Void)?
    var onRetry: (() -> Void)?

    private let headerLabel = NSTextField(labelWithString: "Serial interface")
    private let refreshButton = ConsoleButton("Refresh")
    private let scrollView = NSScrollView()
    private let listView = NSView()
    private let emptyView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No supported serial interfaces found.")
    private let retryButton = ConsoleButton("Retry")
    private let footerSeparator = NSBox()
    private let footerLeft = NSTextField(labelWithString: "115200 baud · 8N1")
    private let footerRight = NSTextField(labelWithString: "0 supported")

    private var devices: [SerialDevice] = []
    private var selectedID: String?
    private var activeID: String?
    private var error: String?
    private var rowViews: [InterfaceRowView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        frame.size = NSSize(width: 340, height: 250)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupViews()
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        ConsoleTheme.background.setFill(); shape.fill()
        ConsoleTheme.border.setStroke(); shape.stroke()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 340, height: 250)
    }

    func update(devices: [SerialDevice], selectedID: String?, activeID: String?, error: String?) {
        self.devices = devices
        self.selectedID = selectedID
        self.activeID = activeID
        self.error = error
        rebuildRows()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func layout() {
        super.layout()

        let width = bounds.width

        headerLabel.frame = NSRect(x: 16, y: bounds.height - 36, width: 180, height: 18)
        refreshButton.setFrameSize(NSSize(width: 60, height: 24))
        refreshButton.frame = NSRect(
            x: width - refreshButton.frame.width - 16,
            y: bounds.height - 39,
            width: refreshButton.frame.width,
            height: 24
        )

        footerSeparator.frame = NSRect(x: 0, y: 35, width: width, height: 1)
        footerLeft.frame = NSRect(x: 16, y: 12, width: 150, height: 14)
        footerRight.frame = NSRect(x: width - 116, y: 12, width: 100, height: 14)

        scrollView.frame = NSRect(x: 8, y: 42, width: width - 16, height: 166)
        emptyView.frame = scrollView.frame

        layoutRows()
        layoutEmptyView()
    }

    private func setupViews() {
        addSubview(headerLabel)
        addSubview(refreshButton)
        addSubview(scrollView)
        addSubview(emptyView)
        addSubview(footerSeparator)
        addSubview(footerLeft)
        addSubview(footerRight)

        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        refreshButton.font = .systemFont(ofSize: 12, weight: .regular)
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = listView

        listView.translatesAutoresizingMaskIntoConstraints = true

        emptyView.addSubview(emptyLabel)
        emptyView.addSubview(retryButton)
        emptyLabel.alignment = .center
        emptyLabel.font = .systemFont(ofSize: 12, weight: .regular)
        emptyLabel.lineBreakMode = .byWordWrapping
        retryButton.font = .systemFont(ofSize: 12, weight: .regular)
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryTapped)

        footerSeparator.boxType = .separator
        footerLeft.font = .systemFont(ofSize: 11, weight: .regular)
        footerRight.font = .systemFont(ofSize: 11, weight: .regular)
        footerRight.alignment = .right

        applyColors()
        rebuildRows()
    }

    private func rebuildRows() {
        for row in rowViews {
            row.removeFromSuperview()
        }

        rowViews = devices.map { device in
            let row = InterfaceRowView()
            row.device = device
            row.isSelectedDevice = device.stableID == selectedID
            row.isActiveDevice = device.stableID == activeID
            row.onClick = { [weak self, device] in self?.onSelect?(device) }
            listView.addSubview(row)
            return row
        }

        let supportedText = devices.count == 1 ? "1 supported" : "\(devices.count) supported"
        footerRight.stringValue = supportedText
        emptyView.isHidden = !devices.isEmpty
        scrollView.isHidden = devices.isEmpty
        emptyLabel.stringValue = error?.isEmpty == false ? error! : "No supported serial interfaces found."
        applyColors()
        needsLayout = true
    }

    private func layoutRows() {
        let rowWidth = scrollView.contentSize.width
        let rowHeight: CGFloat = 74
        let rowGap: CGFloat = 6
        let contentHeight = max(scrollView.contentSize.height, CGFloat(rowViews.count) * rowHeight + CGFloat(max(0, rowViews.count - 1)) * rowGap)
        listView.frame = NSRect(
            x: 0,
            y: 0,
            width: rowWidth,
            height: contentHeight
        )

        for (index, row) in rowViews.enumerated() {
            let y = contentHeight - CGFloat(index + 1) * rowHeight - CGFloat(index) * rowGap
            row.frame = NSRect(x: 0, y: y, width: rowWidth, height: rowHeight)
            row.needsLayout = true
        }
    }

    private func layoutEmptyView() {
        let labelWidth = emptyView.bounds.width - 40
        emptyLabel.frame = NSRect(x: 20, y: 86, width: labelWidth, height: 34)
        retryButton.setFrameSize(NSSize(width: 60, height: 26))
        retryButton.frame = NSRect(
            x: (emptyView.bounds.width - retryButton.frame.width) / 2,
            y: 54,
            width: retryButton.frame.width,
            height: 26
        )
    }

    private func applyColors() {
        needsDisplay = true
        headerLabel.textColor = ConsoleTheme.text
        refreshButton.contentTintColor = ConsoleTheme.accent
        emptyLabel.textColor = error == nil ? .secondaryLabelColor : .systemRed
        footerLeft.textColor = ConsoleTheme.secondary
        footerRight.textColor = ConsoleTheme.secondary

        for row in rowViews {
            row.updateColors()
        }
    }

    @objc private func refreshTapped() {
        onRefresh?()
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}

private final class InterfaceRowView: NSButton {
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // The labels belong to one device-selection button, not separate click targets.
        super.hitTest(point) == nil ? nil : self
    }
    override func draw(_ dirtyRect: NSRect) {
        if isSelectedDevice || cell?.isHighlighted == true {
            ConsoleTheme.pickerSelection.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).stroke()
        }
    }
    var device: SerialDevice? {
        didSet { updateText() }
    }

    var isSelectedDevice = false {
        didSet { updateColors() }
    }

    var isActiveDevice = false {
        didSet { updateText(); updateColors() }
    }

    var onClick: (() -> Void)?

    private let checkmark = NSTextField(labelWithString: "✓")
    private let productLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let serialLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    override func layout() {
        super.layout()

        let inset: CGFloat = 8
        checkmark.frame = NSRect(x: inset, y: 43, width: 18, height: 16)
        statusLabel.frame = NSRect(x: bounds.width - 82, y: 44, width: 70, height: 14)
        productLabel.frame = NSRect(x: 32, y: 43, width: bounds.width - 124, height: 17)
        serialLabel.frame = NSRect(x: 32, y: 24, width: bounds.width - 44, height: 14)
        pathLabel.frame = NSRect(x: 32, y: 8, width: bounds.width - 44, height: 13)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 6
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(rowTapped)

        for subview in [checkmark, productLabel, statusLabel, serialLabel, pathLabel] {
            addSubview(subview)
            subview.lineBreakMode = .byTruncatingTail
        }

        checkmark.font = .systemFont(ofSize: 13, weight: .semibold)
        productLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.alignment = .right
        serialLabel.font = .systemFont(ofSize: 11, weight: .regular)
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)

        updateText()
        updateColors()
    }

    @objc private func rowTapped() {
        onClick?()
    }

    private func updateText() {
        guard let device else {
            productLabel.stringValue = ""
            statusLabel.stringValue = ""
            serialLabel.stringValue = ""
            pathLabel.stringValue = ""
            return
        }

        productLabel.stringValue = device.product.isEmpty ? "Serial interface" : device.product
        statusLabel.stringValue = isActiveDevice ? "Capturing" : "Available"
        serialLabel.stringValue = "Serial \(shortSerial(device.serialNumber))"
        pathLabel.stringValue = URL(fileURLWithPath: device.path).lastPathComponent
        setAccessibilityLabel("\(device.product), serial \(device.serialNumber), \(statusLabel.stringValue)")
        toolTip = device.displayName
    }

    func updateColors() {
        needsDisplay = true
        checkmark.stringValue = isSelectedDevice ? "✓" : ""
        checkmark.textColor = ConsoleTheme.accent
        productLabel.textColor = ConsoleTheme.text
        statusLabel.textColor = isActiveDevice ? ConsoleTheme.green : ConsoleTheme.secondary
        serialLabel.textColor = ConsoleTheme.secondary
        pathLabel.textColor = ConsoleTheme.tertiary
    }

    private func shortSerial(_ serial: String) -> String {
        guard serial.count > 4 else { return serial }
        return "...\(serial.suffix(4))"
    }
}
