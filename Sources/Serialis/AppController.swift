import AppKit
import SerialisCore

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let log = LogViewController()
    private let sidebar = NSTableView()
    private let titleLabel = NSTextField(labelWithString: "Live session")
    private let detailLabel = NSTextField(labelWithString: "Waiting for serial data")
    private let statusLabel = NSTextField(labelWithString: "Starting capture…")
    private let positionLabel = NSTextField(labelWithString: "Following latest")
    private let pauseButton = NSButton(title: "Pause Display", target: nil, action: nil)
    private let jumpButton = NSButton(title: "Jump to Latest", target: nil, action: nil)
    private let searchField = NSSearchField()
    private let searchStatus = NSTextField(labelWithString: "")
    private let inspectorScroll = NSScrollView()
    private let inspectorText = NSTextView()
    private let picker = NSPopUpButton()
    private let pickerDetail = NSTextField(wrappingLabelWithString: "")
    private let settingsPopover = NSPopover()
    private let discovery = DeviceDiscovery()
    private var capture: CaptureController!
    private var instanceLock: AppInstanceLock?
    private var latest: CaptureUpdate?
    private var sessions: [SessionSnapshot] = []
    private var devices: [SerialDevice] = []
    private var attemptedDevice: SerialDevice?
    private var paused = false
    private var viewingHistory = false
    private var lastMatch: Range<UInt64>?
    private var lastQuery = ""
    private var searchTask: DispatchWorkItem?
    private let smokeTest = CommandLine.arguments.contains("--ui-smoke")
    private let smokeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Serialis-smoke-\(UUID().uuidString)")
    private let searchQueue = DispatchQueue(label: "Serialis.search", qos: .userInitiated)
    private let historyQueue = DispatchQueue(label: "Serialis.history", qos: .userInitiated)
    private var root: URL {
        if smokeTest { return smokeRoot }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Serialis/Sessions", isDirectory: true)
    }
    private var selectedID: String? {
        get { UserDefaults.standard.string(forKey: "selectedInterface") }
        set { UserDefaults.standard.set(newValue, forKey: "selectedInterface") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            instanceLock = try AppInstanceLock(directory: root)
            sessions = try SessionCatalog.list(rootDirectory: root)
            capture = try CaptureController(rootDirectory: root)
            buildMenu()
            buildWindow()
            capture.onUpdate = { [weak self] update in self?.received(update) }
            discovery.onChange = { [weak self] devices in self?.devicesChanged(devices) }
            if !smokeTest { capture.start(); discovery.start() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if smokeTest { DispatchQueue.main.async { self.runUISmokeTest() } }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activeSearchCancellation?.cancel()
        searchTask?.cancel()
        capture?.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu(title: "Serialis")
        app.submenu?.addItem(withTitle: "About Serialis", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Quit Serialis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let export = edit.submenu!.addItem(withTitle: "Export Selected Rows…", action: #selector(LogViewController.exportSelection(_:)), keyEquivalent: "e")
        export.target = log
        menu.addItem(edit)
        let find = NSMenuItem()
        find.submenu = NSMenu(title: "Find")
        let focus = find.submenu!.addItem(withTitle: "Find…", action: #selector(focusSearch), keyEquivalent: "f")
        focus.target = self
        let next = find.submenu!.addItem(withTitle: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        next.target = self
        let previous = find.submenu!.addItem(withTitle: "Find Previous", action: #selector(findPrevious), keyEquivalent: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        previous.target = self
        menu.addItem(find)
        NSApp.mainMenu = menu
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Serialis"
        window.minSize = NSSize(width: 900, height: 540)
        window.center()
        window.setFrameAutosaveName("Serialis.main")
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        window.contentView = content

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let headings = NSStackView(views: [titleLabel, detailLabel])
        headings.orientation = .vertical
        headings.alignment = .leading
        headings.spacing = 3
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.bezelStyle = .rounded
        jumpButton.target = self
        jumpButton.action = #selector(jumpLatest)
        jumpButton.bezelStyle = .rounded
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [headings, spacer, pauseButton,
            button("Inspector", #selector(toggleInspector)), button("Settings", #selector(showSettings(_:)))])
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        content.addArrangedSubview(header)

        searchField.placeholderString = "Find in session · exact text"
        searchField.target = self
        searchField.action = #selector(findNext)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = true
        searchField.widthAnchor.constraint(equalToConstant: 280).isActive = true
        searchStatus.font = .systemFont(ofSize: 11)
        searchStatus.textColor = .secondaryLabelColor
        let searchBar = NSStackView(views: [searchField, button("Previous", #selector(findPrevious)),
            button("Next", #selector(findNext)), searchStatus, NSView(), jumpButton])
        searchBar.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 12, right: 20)
        content.addArrangedSubview(searchBar)

        let sessionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        sessionColumn.width = 190
        sidebar.addTableColumn(sessionColumn)
        sidebar.headerView = nil
        sidebar.rowHeight = 54
        sidebar.style = .sourceList
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel("Sessions")
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        let sidebarHeading = NSTextField(labelWithString: "SESSIONS")
        sidebarHeading.font = .systemFont(ofSize: 10, weight: .semibold)
        sidebarHeading.textColor = .secondaryLabelColor
        let side = NSStackView(views: [sidebarHeading, sidebarScroll, button("Open Sessions Folder", #selector(openSessionsFolder))])
        side.orientation = .vertical
        side.alignment = .leading
        side.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        side.widthAnchor.constraint(equalToConstant: 215).isActive = true
        sidebarScroll.widthAnchor.constraint(equalTo: side.widthAnchor, constant: -24).isActive = true

        inspectorText.isEditable = false
        inspectorText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        inspectorText.textContainerInset = NSSize(width: 12, height: 12)
        inspectorText.isHorizontallyResizable = false
        inspectorText.autoresizingMask = [.width]
        inspectorText.textContainer?.widthTracksTextView = true
        inspectorScroll.documentView = inspectorText
        inspectorScroll.hasVerticalScroller = true
        inspectorScroll.widthAnchor.constraint(equalToConstant: 280).isActive = true
        inspectorScroll.isHidden = true
        let body = NSStackView(views: [side, log.view, inspectorScroll])
        body.alignment = .top
        body.spacing = 1
        content.addArrangedSubview(body)
        for child in [side, log.view, inspectorScroll] {
            child.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        }
        log.view.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        log.onPositionChange = { [weak self] in self?.updatePosition() }

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        positionLabel.font = .systemFont(ofSize: 11)
        positionLabel.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [statusLabel, NSView(), positionLabel])
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        content.addArrangedSubview(footer)
        for child in [header, searchBar, body, footer] {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        buildSettings()
    }

    private func buildSettings() {
        let heading = NSTextField(labelWithString: "Serial interface")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        picker.target = self
        picker.action = #selector(chooseDevice)
        pickerDetail.font = .systemFont(ofSize: 11)
        pickerDetail.textColor = .secondaryLabelColor
        let baud = NSTextField(labelWithString: "115200 baud · 8 data bits · no parity · 1 stop bit")
        baud.font = .systemFont(ofSize: 10)
        let controls = NSStackView(views: [button("Refresh", #selector(refreshDevices)), button("Retry", #selector(retryDevice))])
        let stack = NSStackView(views: [heading, picker, pickerDetail, baud, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        picker.widthAnchor.constraint(equalToConstant: 300).isActive = true
        pickerDetail.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let controller = NSViewController()
        controller.view = stack
        settingsPopover.contentViewController = controller
        settingsPopover.contentSize = NSSize(width: 340, height: 235)
        settingsPopover.behavior = .transient
    }

    private func received(_ update: CaptureUpdate) {
        latest = update
        statusLabel.stringValue = "\(update.device == nil ? "○" : "●") \(update.status) · \(formatBytes(update.snapshot.byteCount)) saved"
        statusLabel.textColor = update.isError ? .systemRed : .secondaryLabelColor
        if !viewingHistory && !paused {
            do { try log.show(update.snapshot) }
            catch { showError(error) }
        }
        detailLabel.stringValue = viewingHistory ? "Saved session · live capture continues" : "\(update.snapshot.directory.lastPathComponent) · raw bytes saved automatically"
        updatePosition()
        updateInspector()
    }

    private func devicesChanged(_ connected: [SerialDevice]) {
        devices = connected
        // A remembered board that is absent must never be replaced by a different board.
        if selectedID == nil, connected.count == 1 { selectedID = connected[0].stableID }
        let chosen = connected.first { $0.stableID == selectedID }
        picker.removeAllItems()
        picker.addItem(withTitle: chosen == nil ? "Choose a supported interface…" : "Select interface…")
        for device in connected {
            picker.addItem(withTitle: "\(device.product) · …\(device.serialNumber.suffix(6))")
        }
        if let chosen, let index = connected.firstIndex(of: chosen) {
            picker.selectItem(at: index + 1)
            pickerDetail.stringValue = "\(chosen.path)\nSerial: \(chosen.serialNumber)"
            if attemptedDevice != chosen {
                attemptedDevice = chosen
                capture.connect(chosen)
            }
        } else {
            pickerDetail.stringValue = connected.isEmpty ? "No supported interfaces connected. Your selected interface will reconnect automatically." : "Choose the interface to capture. The selection is remembered."
            if attemptedDevice != nil { capture.disconnected(); attemptedDevice = nil }
        }
    }

    @objc private func chooseDevice() {
        let index = picker.indexOfSelectedItem - 1
        guard devices.indices.contains(index) else { return }
        selectedID = devices[index].stableID
        attemptedDevice = nil
        devicesChanged(devices)
    }
    @objc private func refreshDevices() { discovery.refresh() }
    @objc private func retryDevice() { attemptedDevice = nil; discovery.refresh() }
    @objc private func showSettings(_ sender: NSButton) {
        settingsPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func togglePause() {
        guard !viewingHistory else { return }
        paused.toggle()
        pauseButton.title = paused ? "Resume Display" : "Pause Display"
        if !paused, let latest {
            do { try log.show(latest.snapshot, follow: true); log.jumpToLatest() }
            catch { showError(error) }
        }
        updatePosition()
    }
    @objc private func jumpLatest() {
        if viewingHistory { sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        paused = false
        pauseButton.title = "Pause Display"
        if let latest { try? log.show(latest.snapshot, follow: true) }
        log.jumpToLatest()
    }

    private func updatePosition() {
        if viewingHistory {
            positionLabel.stringValue = "Viewing history"
            jumpButton.title = "Return to Live"
        } else {
            let unseen = (latest?.snapshot.byteCount ?? 0) - min(latest?.snapshot.byteCount ?? 0, log.snapshot?.byteCount ?? 0)
            positionLabel.stringValue = paused ? "Display paused · \(formatBytes(unseen)) captured since pause" : (log.followsLatest ? "Following latest" : "Reading earlier rows · capture continues")
            jumpButton.title = "Jump to Latest"
        }
        pauseButton.isEnabled = !viewingHistory
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count + 1 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = .systemFont(ofSize: 12)
        if row == 0 { field.stringValue = "Live session\nCurrent capture" }
        else {
            let session = sessions[row - 1]
            field.stringValue = "\(session.metadata.startedAt.formatted(date: .abbreviated, time: .shortened))\n\(formatBytes(session.byteCount))"
        }
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        activeSearchCancellation?.cancel()
        searchTask?.cancel()
        lastMatch = nil
        searchStatus.stringValue = ""
        paused = false
        pauseButton.title = "Pause Display"
        let row = sidebar.selectedRow
        viewingHistory = row > 0
        let snapshot = row > 0 && row <= sessions.count ? sessions[row - 1] : latest?.snapshot
        titleLabel.stringValue = viewingHistory ? "Saved session" : "Live session"
        if viewingHistory, let snapshot {
            searchStatus.stringValue = "Opening session…"
            log.clear(message: "Opening saved session…")
            historyQueue.async { [weak self] in
                let result = Result { try SessionReader.loadSnapshot(directory: snapshot.directory) }
                DispatchQueue.main.async {
                    guard let self, self.viewingHistory, self.sidebar.selectedRow == row else { return }
                    do {
                        try self.log.show(result.get(), follow: true)
                        self.searchStatus.stringValue = ""
                        self.updateInspector()
                    } catch {
                        self.showError(error)
                        self.searchStatus.stringValue = "Could not open session"
                        self.log.clear(message: "Could not open this session.\n\(error.localizedDescription)")
                    }
                }
            }
        } else if let snapshot {
            do { try log.show(snapshot, follow: true) } catch { showError(error) }
        }
        if let latest { received(latest) }
        updatePosition()
    }

    @objc private func focusSearch() { window.makeFirstResponder(searchField) }
    @objc private func findNext() { search(backwards: false) }
    @objc private func findPrevious() { search(backwards: true) }
    private func search(backwards: Bool) {
        activeSearchCancellation?.cancel()
        searchTask?.cancel()
        let query = searchField.stringValue
        guard !query.isEmpty, let reader = log.reader, let snapshot = log.snapshot else { return }
        guard query.utf8.count <= 65536 else { searchStatus.stringValue = "Search text is too long"; return }
        if query != lastQuery { lastMatch = nil; lastQuery = query }
        let prior = lastMatch
        let start = backwards ? (prior.map { $0.lowerBound > 0 ? $0.lowerBound - 1 : snapshot.byteCount } ?? snapshot.byteCount) : (prior.map { $0.lowerBound + 1 } ?? 0)
        searchStatus.stringValue = "Searching…"
        let cancellation = SearchCancellation()
        // A separate token avoids a work item retaining itself through its own closure.
        let task = DispatchWorkItem { [weak self] in
            do {
                var match = try reader.find(Data(query.utf8), from: start, backwards: backwards,
                    snapshot: snapshot, isCancelled: { cancellation.isCancelled })
                if match == nil, !cancellation.isCancelled {
                    match = try reader.find(Data(query.utf8), from: backwards ? snapshot.byteCount : 0,
                        backwards: backwards, snapshot: snapshot, isCancelled: { cancellation.isCancelled })
                }
                guard !cancellation.isCancelled else { return }
                DispatchQueue.main.async {
                    guard let self, self.log.snapshot?.directory == snapshot.directory, self.lastQuery == query,
                          !cancellation.isCancelled else { return }
                    self.lastMatch = match
                    self.searchStatus.stringValue = match.map { "Match at byte \($0.lowerBound)" } ?? "No matches"
                    if let match { do { try self.log.reveal(match) } catch { self.showError(error) } }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.searchStatus.stringValue = error.localizedDescription }
            }
        }
        activeSearchCancellation?.cancel()
        activeSearchCancellation = cancellation
        searchTask = task
        searchQueue.async(execute: task)
    }
    private var activeSearchCancellation: SearchCancellation?

    @objc private func toggleInspector() { inspectorScroll.isHidden.toggle(); updateInspector() }
    private func updateInspector() {
        guard !inspectorScroll.isHidden, let snapshot = log.snapshot else { return }
        var text = "SESSION\n\(snapshot.metadata.startedAt.formatted())\n\n\(formatBytes(snapshot.byteCount))\n\(snapshot.rowCount) display rows\n\nFILES\n\(snapshot.directory.path)\n\nINTERFACES\n"
        for segment in snapshot.metadata.segments {
            text += "\n\(segment.device.displayName)\n\(segment.device.path)\nBytes \(segment.startOffset)…\(segment.endOffset.map(String.init) ?? "live")\n"
        }
        text += "\nEVENTS\n"
        for event in snapshot.metadata.events.suffix(50) { text += "\(event.date.formatted(date: .omitted, time: .standard))  \(event.message)\n" }
        inspectorText.string = text
    }
    @objc private func openSessionsFolder() { NSWorkspace.shared.open(root) }
    private func showError(_ error: Error) { statusLabel.stringValue = error.localizedDescription; statusLabel.textColor = .systemRed }
    private func formatBytes(_ count: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }

    /// Runs against temporary fixtures only; never discovers or opens the user's hardware.
    private func runUISmokeTest() {
        do {
            let writer = try SessionWriter(rootDirectory: smokeRoot)
            for index in 0..<150 {
                try writer.append(Data("[\(index)] Serialis sample · device ready · capture continues\n".utf8))
            }
            received(CaptureUpdate(snapshot: writer.snapshot, status: "Synthetic capture", device: nil, isError: false))
            let before = log.snapshot!.byteCount
            togglePause()
            try writer.append(Data("New bytes while display is paused\n".utf8))
            received(CaptureUpdate(snapshot: writer.snapshot, status: "Synthetic capture", device: nil, isError: false))
            precondition(log.snapshot!.byteCount == before, "Pause must freeze the display")
            togglePause()
            precondition(log.snapshot!.byteCount == writer.snapshot.byteCount, "Resume must include paused bytes")
            try writer.finish()
            if let flag = CommandLine.arguments.firstIndex(of: "--session"), flag + 1 < CommandLine.arguments.count {
                let saved = try SessionReader.loadSnapshot(directory: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                received(CaptureUpdate(snapshot: saved, status: "Large-session UI test", device: nil, isError: false))
            }
            window.contentView?.layoutSubtreeIfNeeded()
            for index in 0..<100 {
                autoreleasepool {
                    if let snapshot = log.snapshot, snapshot.rowCount > 0 {
                        let row = Int(UInt64(index) * (snapshot.rowCount - 1) / 99)
                        log.table.scrollRowToVisible(row)
                        log.table.layoutSubtreeIfNeeded()
                        log.table.displayIfNeeded()
                    }
                }
            }
            log.jumpToLatest()
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(log.view.bounds.height > 200, "Log view must have usable height")
            precondition(log.view.bounds.width > 300, "Log view must have usable width")
            print("UI smoke passed: pause, resume, 100 scroll positions, layout")
            print("Visible log size: \(log.view.bounds.size)")
            if !CommandLine.arguments.contains("--no-snapshot"), let content = window.contentView,
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                }
                let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("benchmark-results/UI-preview.png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                print("Preview: \(url.path)")
            }
            NSApp.terminate(nil)
        } catch {
            fputs("UI smoke failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

private final class SearchCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
