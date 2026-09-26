import AppKit

/// The window has five stable regions. Only the log area grows when resized.
final class ConsoleWorkspace: ConsolePanel {
    let topBar = ConsolePanel()
    let sidebarPanel = ConsolePanel()
    let sessionHeader = ConsolePanel()
    let footer = ConsolePanel()
    let searchBar = ConsolePanel()
    let messageBar = ConsolePanel()
    let sidebarScroll = NSScrollView()
    let titleLabel = ConsoleTheme.label("Today", size: 16, weight: .semibold)
    let detailLabel = ConsoleTheme.label("Current session", size: 11, color: ConsoleTheme.secondary)
    let statusLabel = ConsoleTheme.label("Waiting for interface", size: 10, color: ConsoleTheme.secondary)
    let positionLabel = ConsoleTheme.label("", size: 11, color: ConsoleTheme.accent)
    let captureLabel = ConsoleTheme.label("○  Waiting", color: ConsoleTheme.secondary)
    let elapsedLabel = ConsoleTheme.label("00:00:00", size: 11, color: ConsoleTheme.secondary)
    let savedLabel = ConsoleTheme.label("0 bytes captured", size: 10, color: ConsoleTheme.secondary)
    let recordingLabel = ConsoleTheme.label("Waiting for interface", size: 10, color: ConsoleTheme.secondary)
    let deviceName = ConsoleTheme.label("Serial interface", size: 12)
    let deviceDetail = ConsoleTheme.label("Not connected · 115200 baud", size: 11, color: ConsoleTheme.secondary)
    let pauseButton = ConsoleButton("Pause Display", symbol: "pause")
    let jumpButton = ConsoleButton("Jump to Latest", symbol: "arrow.down")
    let settingsButton = ConsoleButton("Settings", symbol: "chevron.down")
    let themeButton = ConsoleButton(symbol: "moon")
    let findButton = ConsoleButton(symbol: "magnifyingglass")
    let inspectorButton = ConsoleButton(symbol: "info.circle")
    let sidebarButton = ConsoleButton(symbol: "sidebar.left")
    let folderButton = ConsoleButton(symbol: "folder")
    let previousButton = ConsoleButton(symbol: "chevron.up")
    let nextButton = ConsoleButton(symbol: "chevron.down")
    let closeSearchButton = ConsoleButton("Done")
    let searchField = NSSearchField()
    let searchStatus = ConsoleTheme.label("", size: 11, color: ConsoleTheme.secondary)
    var sidebarVisible = true { didSet { needsLayout = true } }
    var inspectorVisible = false { didSet { needsLayout = true } }
    var searchVisible = false { didSet { needsLayout = true } }
    var messageVisible = false { didSet { needsLayout = true } }
    let logView: NSView
    let inspector: NSView
    private let appName = ConsoleTheme.label("Serialis", size: 14, weight: .semibold)
    private let sessionsHeading = ConsoleTheme.label("Sessions", size: 13, weight: .medium, color: ConsoleTheme.secondary)
    private let baudLabel = ConsoleTheme.label("115200 baud", size: 10, color: ConsoleTheme.secondary)
    private let deviceRule = ConsolePanel()
    private var trafficLights: [NSButton] = []

    init(logView: NSView, sidebar: NSTableView, inspector: NSView) {
        self.logView = logView
        self.inspector = inspector
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        topBar.color = ConsoleTheme.chrome; topBar.bottomBorder = true; topBar.draggable = true
        sidebarPanel.color = ConsoleTheme.sidebar; sidebarPanel.rightBorder = true
        sessionHeader.bottomBorder = true
        footer.color = ConsoleTheme.chrome
        searchBar.color = ConsoleTheme.gutter; searchBar.bottomBorder = true
        messageBar.color = ConsoleTheme.banner; messageBar.bottomBorder = true
        deviceRule.color = ConsoleTheme.border
        elapsedLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        settingsButton.outlined = true
        settingsButton.symbolAfterTitle = true
        themeButton.outlined = true
        for panel in [topBar, sidebarPanel, sessionHeader, searchBar, messageBar, footer, logView, inspector] { addSubview(panel) }
        for child in [sidebarButton, appName, themeButton, settingsButton, captureLabel, elapsedLabel] { topBar.addSubview(child) }
        for child in [titleLabel, detailLabel, pauseButton, findButton, inspectorButton] { sessionHeader.addSubview(child) }
        sidebarScroll.documentView = sidebar
        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.scrollerStyle = .overlay
        for child in [sessionsHeading, folderButton, sidebarScroll, deviceRule, deviceName, deviceDetail] { sidebarPanel.addSubview(child) }
        for child in [searchField, previousButton, nextButton, searchStatus, closeSearchButton] { searchBar.addSubview(child) }
        for child in [positionLabel, jumpButton] { messageBar.addSubview(child) }
        for child in [statusLabel, baudLabel, savedLabel, recordingLabel] { footer.addSubview(child) }
        searchField.placeholderString = "Find in session"
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        for (button, name) in [(sidebarButton, "Toggle sessions"), (folderButton, "Open sessions folder"),
            (findButton, "Find in session"), (inspectorButton, "Session inspector"),
            (previousButton, "Previous match"), (nextButton, "Next match")] {
            button.toolTip = name; button.setAccessibilityLabel(name)
        }
        updateThemeButton()
    }
    required init?(coder: NSCoder) { fatalError("Use init(logView:sidebar:inspector:)") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateThemeButton()
    }

    func updateThemeButton() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        themeButton.symbol = dark ? "sun.max" : "moon"
        let action = dark ? "Switch to light theme" : "Switch to dark theme"
        themeButton.toolTip = action
        themeButton.setAccessibilityLabel(action)
    }

    func installWindowButtons(from window: NSWindow) {
        // These remain actual AppKit window buttons, including their native accessibility/actions.
        for button in trafficLights { button.removeFromSuperview() }
        trafficLights.removeAll()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.removeFromSuperview()
            button.isHidden = false
            topBar.addSubview(button)
            trafficLights.append(button)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let side: CGFloat = sidebarVisible ? 224 : 0
        let inspectorWidth: CGFloat = inspectorVisible ? 280 : 0
        let mainWidth = width - side
        topBar.frame = NSRect(x: 0, y: 0, width: width, height: 64)
        for (index, button) in trafficLights.enumerated() { button.setFrameOrigin(NSPoint(x: 18 + index * 20, y: 25)) }
        sidebarButton.frame = NSRect(x: 94, y: 17, width: 32, height: 30)
        appName.frame = NSRect(x: 134, y: 23, width: 160, height: 20)
        settingsButton.frame = NSRect(x: width - 405, y: 17, width: 106, height: 30)
        themeButton.frame = NSRect(x: width - 445, y: 17, width: 32, height: 30)
        captureLabel.frame = NSRect(x: width - 270, y: 25, width: 145, height: 18)
        elapsedLabel.frame = NSRect(x: width - 114, y: 25, width: 96, height: 18)
        sidebarPanel.isHidden = !sidebarVisible
        sidebarPanel.frame = NSRect(x: 0, y: 64, width: side, height: height - 92)
        sessionsHeading.frame = NSRect(x: 20, y: 17, width: 140, height: 20)
        folderButton.frame = NSRect(x: 178, y: 13, width: 28, height: 26)
        sidebarScroll.frame = NSRect(x: 8, y: 47, width: 208, height: max(0, sidebarPanel.bounds.height - 129))
        deviceRule.frame = NSRect(x: 16, y: sidebarPanel.bounds.height - 75, width: 192, height: 1)
        deviceName.frame = NSRect(x: 20, y: sidebarPanel.bounds.height - 59, width: 184, height: 18)
        deviceDetail.frame = NSRect(x: 20, y: sidebarPanel.bounds.height - 36, width: 184, height: 18)
        sessionHeader.frame = NSRect(x: side, y: 64, width: mainWidth, height: 74)
        titleLabel.frame = NSRect(x: 24, y: 17, width: max(120, mainWidth - 300), height: 22)
        detailLabel.frame = NSRect(x: 24, y: 43, width: max(120, mainWidth - 300), height: 17)
        pauseButton.frame = NSRect(x: mainWidth - 206, y: 19, width: 130, height: 32)
        findButton.frame = NSRect(x: mainWidth - 73, y: 19, width: 32, height: 32)
        inspectorButton.frame = NSRect(x: mainWidth - 38, y: 19, width: 32, height: 32)
        var y: CGFloat = 138
        searchBar.isHidden = !searchVisible
        searchBar.frame = NSRect(x: side, y: y, width: mainWidth, height: 42)
        searchField.frame = NSRect(x: 16, y: 8, width: min(320, mainWidth - 260), height: 26)
        previousButton.frame = NSRect(x: searchField.frame.maxX + 6, y: 8, width: 28, height: 26)
        nextButton.frame = previousButton.frame.offsetBy(dx: 28, dy: 0)
        searchStatus.frame = NSRect(x: nextButton.frame.maxX + 12, y: 13, width: max(0, mainWidth - nextButton.frame.maxX - 86), height: 17)
        closeSearchButton.frame = NSRect(x: mainWidth - 62, y: 8, width: 50, height: 26)
        if searchVisible { y += 42 }
        messageBar.isHidden = !messageVisible
        messageBar.frame = NSRect(x: side, y: y, width: mainWidth, height: 34)
        positionLabel.frame = NSRect(x: 18, y: 9, width: max(0, mainWidth - 180), height: 17)
        jumpButton.frame = NSRect(x: mainWidth - 150, y: 3, width: 138, height: 28)
        if messageVisible { y += 34 }
        logView.frame = NSRect(x: side, y: y, width: mainWidth - inspectorWidth, height: max(0, height - y - 28))
        inspector.isHidden = !inspectorVisible
        inspector.frame = NSRect(x: width - inspectorWidth, y: y, width: inspectorWidth, height: max(0, height - y - 28))
        footer.frame = NSRect(x: 0, y: height - 28, width: width, height: 28)
        statusLabel.frame = NSRect(x: 16, y: 8, width: 192, height: 14)
        baudLabel.frame = NSRect(x: 224, y: 8, width: 110, height: 14)
        savedLabel.frame = NSRect(x: 340, y: 8, width: 230, height: 14)
        recordingLabel.frame = NSRect(x: width - 240, y: 8, width: 222, height: 14)
        recordingLabel.alignment = .right
    }
}

final class SessionSelectionRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        ConsoleTheme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

final class SessionCell: NSView {
    let title = ConsoleTheme.label("", size: 13)
    let detail = ConsoleTheme.label("", size: 11, color: ConsoleTheme.secondary)
    let icon = NSImageView()
    let mark = ConsoleTheme.label("", size: 12, color: ConsoleTheme.green)
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [title, detail, mark] { addSubview(label) }
        icon.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        icon.contentTintColor = ConsoleTheme.tertiary
        addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func layout() {
        super.layout()
        mark.frame = NSRect(x: 12, y: 13, width: 18, height: 18)
        icon.frame = NSRect(x: 12, y: 13, width: 13, height: 16)
        title.frame = NSRect(x: 34, y: 10, width: bounds.width - 42, height: 20)
        detail.frame = NSRect(x: 34, y: 34, width: bounds.width - 42, height: 17)
    }
}
