import AppKit
import SerialisCore

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let log = LogViewController()
    private let sidebar = NSTableView()
    private var workspace: ConsoleWorkspace!
    private let inspector = SessionInspectorView(frame: .zero)
    private let picker = InterfacePickerView(frame: .zero)
    private var titleLabel: NSTextField { workspace.titleLabel }
    private var detailLabel: NSTextField { workspace.detailLabel }
    private var statusLabel: NSTextField { workspace.statusLabel }
    private var positionLabel: NSTextField { workspace.positionLabel }
    private var pauseButton: ConsoleButton { workspace.pauseButton }
    private var jumpButton: ConsoleButton { workspace.jumpButton }
    private var searchField: NSSearchField { workspace.searchField }
    private var searchStatus: NSTextField { workspace.searchStatus }
    private var elapsedTimer: Timer?
    private var inspectorUpdatedAt = Date.distantPast
    // A nil snapshot is the current session; headings cannot be selected.
    private enum SidebarItem { case heading(String), session(SessionSnapshot?) }
    private var sidebarItems: [SidebarItem] = [.heading("Today"), .session(nil)]
    private let liveRow = 1
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
    private var searchResult: SessionSearchResult?
    private var lastQuery = ""
    private var searchTask: DispatchWorkItem?
    private let smokeTest = CommandLine.arguments.contains("--ui-smoke")
    private let smokeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Serialis-smoke-\(UUID().uuidString)")
    private let searchQueue = DispatchQueue(label: "Serialis.search", qos: .userInitiated)
    private let historyQueue = DispatchQueue(label: "Serialis.history", qos: .userInitiated)
    private var root: URL {
        if smokeTest { return smokeRoot }
        return SessionLocation.root
    }
    private var selectedID: String? {
        get { UserDefaults.standard.string(forKey: "selectedInterface") }
        set { UserDefaults.standard.set(newValue, forKey: "selectedInterface") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            instanceLock = try AppInstanceLock(directory: root)
            sessions = try SessionCatalog.list(rootDirectory: root)
            capture = try CaptureController(rootDirectory: root, selectedDeviceID: smokeTest ? nil : selectedID)
            buildMenu()
            buildWindow()
            capture.onUpdate = { [weak self] update in self?.received(update) }
            discovery.onChange = { [weak self] devices in self?.devicesChanged(devices) }
            if !smokeTest { capture.start(); discovery.start() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if smokeTest { Task { @MainActor in await self.runUISmokeTest() } }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activeSearchCancellation?.cancel()
        searchTask?.cancel()
        elapsedTimer?.invalidate()
        capture?.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu(title: "Serialis")
        let about = app.submenu!.addItem(withTitle: "About Serialis", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let installCLI = app.submenu!.addItem(withTitle: "Install Command-Line Tool…", action: #selector(installCommandLineTool), keyEquivalent: "")
        installCLI.target = self
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Quit Serialis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let export = edit.submenu!.addItem(withTitle: "Export Selected Text…", action: #selector(LogViewController.exportSelection(_:)), keyEquivalent: "e")
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

    @objc private func installCommandLineTool() { CLIInstaller.install() }

    @objc private func showAbout() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "Created by\nVinay Kumar Rasala (Xplo8E)\n\nLicensed under GNU GPLv3 only\nProvided without warranty.",
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph]
        )
        // Keep the native About panel's bundle icon and version information.
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func buildWindow() {
        if !smokeTest, let saved = UserDefaults.standard.string(forKey: "preferredAppearance") {
            if saved == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
            if saved == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Serialis"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 960, height: 540)
        window.center()
        if !smokeTest { window.setFrameAutosaveName("Serialis.main") }
        if smokeTest, CommandLine.arguments.contains("dark") { window.appearance = NSAppearance(named: .darkAqua) }
        if smokeTest, CommandLine.arguments.contains("light") { window.appearance = NSAppearance(named: .aqua) }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.width = 208
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.rowHeight = 60
        sidebar.intercellSpacing = .zero
        sidebar.style = .plain
        sidebar.backgroundColor = ConsoleTheme.sidebar
        sidebar.selectionHighlightStyle = .regular
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityLabel("Sessions")
        rebuildSidebar()
        workspace = ConsoleWorkspace(logView: log.view, sidebar: sidebar, inspector: inspector)
        window.contentView = workspace
        workspace.installWindowButtons(from: window)
        let actions: [(NSButton, Selector)] = [
            (pauseButton, #selector(togglePause)), (jumpButton, #selector(jumpLatest)),
            (workspace.settingsButton, #selector(showSettings(_:))),
            (workspace.themeButton, #selector(toggleTheme)),
            (workspace.findButton, #selector(focusSearch)),
            (workspace.inspectorButton, #selector(toggleInspector)),
            (workspace.sidebarButton, #selector(toggleSidebar)),
            (workspace.folderButton, #selector(openSessionsFolder)),
            (workspace.previousButton, #selector(findPrevious)),
            (workspace.nextButton, #selector(findNext)),
            (workspace.closeSearchButton, #selector(closeSearch))
        ]
        for (button, action) in actions { button.target = self; button.action = action }
        searchField.target = self
        searchField.action = #selector(findNext)
        log.onPositionChange = { [weak self] in self?.updatePosition() }
        inspector.onClose = { [weak self] in self?.workspace.inspectorVisible = false }
        sidebar.selectRowIndexes(IndexSet(integer: liveRow), byExtendingSelection: false)
        buildSettings()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateElapsed() }
    }

    @objc private func toggleTheme() {
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
        // Apply to the whole app, including the interface popover and file panels.
        NSApp.appearance = appearance
        window.appearance = appearance
        settingsPopover.appearance = appearance
        // AppKit recreates its title-bar controls when the window appearance changes.
        workspace.installWindowButtons(from: window)
        if !smokeTest { UserDefaults.standard.set(dark ? "light" : "dark", forKey: "preferredAppearance") }
        workspace.updateThemeButton()
    }

    private func buildSettings() {
        picker.onSelect = { [weak self] device in
            guard let self, !self.capture.isFollower else { return }
            self.selectedID = device.stableID
            self.attemptedDevice = nil
            self.devicesChanged(self.devices)
        }
        picker.onRefresh = { [weak self] in self?.discovery.refresh() }
        picker.onRetry = { [weak self] in self?.retryDevice() }
        let controller = NSViewController()
        controller.view = picker
        settingsPopover.contentViewController = controller
        settingsPopover.contentSize = NSSize(width: 340, height: 250)
        settingsPopover.behavior = .transient
    }

    private func updatePicker() {
        picker.update(devices: devices, selectedID: capture?.isFollower == true ? latest?.selectedDeviceID : selectedID, activeID: latest?.device?.stableID,
                      error: latest?.isError == true ? latest?.status : nil,
                      readOnly: capture?.isFollower == true)
    }

    private func updateElapsed() {
        guard let startedAt = latest?.snapshot.metadata.startedAt else { return }
        let end = latest?.snapshot.metadata.endedAt ?? Date()
        let seconds = max(0, Int(end.timeIntervalSince(startedAt)))
        workspace.elapsedLabel.stringValue = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func sessionTitle(_ snapshot: SessionSnapshot) -> String {
        let date = snapshot.metadata.startedAt
        let day = Calendar.current.isDateInToday(date) ? "Today" : date.formatted(date: .abbreviated, time: .omitted)
        return "\(day), \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func received(_ update: CaptureUpdate) {
        let previousDevice = latest?.device
        let previousError = latest?.isError
        latest = update
        if sessions.contains(where: { $0.metadata.id == update.snapshot.metadata.id }) {
            sessions.removeAll { $0.metadata.id == update.snapshot.metadata.id }
            rebuildSidebar()
        }
        let connected = update.device != nil && !update.isError
        statusLabel.stringValue = connected ? "●  Interface connected" : (update.isError ? "●  Capture error" : "○  Waiting for interface")
        statusLabel.textColor = update.isError ? .systemRed : ConsoleTheme.secondary
        statusLabel.toolTip = update.status
        workspace.captureLabel.stringValue = connected ? "●  Capturing" : (update.isError ? "●  Capture error" : "○  Waiting")
        workspace.captureLabel.textColor = connected ? ConsoleTheme.green : ConsoleTheme.secondary
        workspace.recordingLabel.stringValue = connected ? "Raw recording active" : "Raw recording idle"
        workspace.recordingLabel.textColor = connected ? ConsoleTheme.green : ConsoleTheme.secondary
        if capture?.isFollower == true {
            workspace.recordingLabel.stringValue = update.ownerEnded ? "Capture ended" : "Following external capture"
            workspace.recordingLabel.toolTip = "The process that started capture owns the interface. Closing this window will not stop it."
        }
        if update.ownerEnded {
            statusLabel.stringValue = "○  Capture ended"
            workspace.captureLabel.stringValue = "○  Stopped"
        }
        workspace.savedLabel.stringValue = "\(formatBytes(update.snapshot.byteCount)) captured"
        workspace.deviceName.stringValue = update.device?.product ?? "Serial interface"
        workspace.deviceDetail.stringValue = connected ? "Connected · 115200 baud" : "Not connected · 115200 baud"
        if !viewingHistory && !paused {
            do { try log.show(update.snapshot) }
            catch { showError(error) }
        }
        updateSessionHeading()
        if let cell = sidebar.view(atColumn: 0, row: liveRow, makeIfNecessary: false) as? SessionCell {
            configure(cell, snapshot: update.snapshot, live: true)
        }
        if previousDevice != update.device || previousError != update.isError { updatePicker() }
        updateElapsed()
        updatePosition()
        if Date().timeIntervalSince(inspectorUpdatedAt) >= 1 { updateInspector() }
        refreshSearchCount()
    }

    private func updateSessionHeading() {
        guard let snapshot = viewingHistory ? log.snapshot : latest?.snapshot else { return }
        titleLabel.stringValue = sessionTitle(snapshot)
        detailLabel.stringValue = "\(viewingHistory ? "Saved session" : "Current session") · \(formatBytes(snapshot.byteCount)) captured"
    }

    private func devicesChanged(_ connected: [SerialDevice]) {
        devices = connected
        if capture.isFollower { updatePicker(); return }
        // A remembered board that is absent must never be replaced by a different board.
        if selectedID == nil, connected.count == 1 { selectedID = connected[0].stableID }
        if let chosen = connected.first(where: { $0.stableID == selectedID }) {
            if attemptedDevice != chosen {
                attemptedDevice = chosen
                capture.connect(chosen)
            }
        } else if attemptedDevice != nil {
            capture.disconnected()
            attemptedDevice = nil
        }
        updatePicker()
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
        pauseButton.symbol = paused ? "play" : "pause"
        if !paused, let latest {
            do { try log.show(latest.snapshot, follow: true); log.jumpToLatest() }
            catch { showError(error) }
        }
        updatePosition()
        refreshSearchCount()
    }
    @objc private func jumpLatest() {
        if viewingHistory { sidebar.selectRowIndexes(IndexSet(integer: liveRow), byExtendingSelection: false) }
        paused = false
        pauseButton.title = "Pause Display"
        pauseButton.symbol = "pause"
        if let latest { try? log.show(latest.snapshot, follow: true) }
        log.jumpToLatest()
    }

    private func updatePosition() {
        guard workspace != nil else { return }
        workspace.showingHistory = viewingHistory
        let disconnected = latest?.device == nil && (latest?.snapshot.metadata.segments.isEmpty == false)
        workspace.messageBar.color = disconnected || latest?.isError == true ? ConsoleTheme.warning : ConsoleTheme.banner
        workspace.messageBar.needsDisplay = true
        positionLabel.textColor = disconnected || latest?.isError == true ? ConsoleTheme.warningText : ConsoleTheme.accent
        jumpButton.isHidden = false
        jumpButton.title = "Jump to Latest"
        if viewingHistory {
            positionLabel.stringValue = "Viewing a saved session · current capture continues"
            jumpButton.title = "Return to Live"
        } else if paused {
            let bytes = latest?.snapshot.byteCount ?? 0
            let unseen = bytes - min(bytes, log.snapshot?.byteCount ?? 0)
            positionLabel.stringValue = "Display paused · \(formatBytes(unseen)) captured since pause"
            jumpButton.title = "Jump to Latest"
        } else if latest?.ownerEnded == true {
            positionLabel.stringValue = "Capture ended · reopen Serialis to start a new capture"
            jumpButton.isHidden = log.followsLatest
        } else if latest?.isError == true || disconnected {
            positionLabel.stringValue = latest?.isError == true ? (latest?.status ?? "Capture error") : "Interface disconnected · waiting to reconnect"
            jumpButton.isHidden = log.followsLatest
        } else {
            positionLabel.stringValue = "Reading earlier logs · capture continues"
            jumpButton.title = "Jump to Latest"
        }
        workspace.messageVisible = !viewingHistory && (paused || !log.followsLatest || disconnected || latest?.isError == true || latest?.ownerEnded == true)
        pauseButton.isEnabled = !viewingHistory
    }

    private func rebuildSidebar() {
        sidebarItems = [.heading("Today"), .session(nil)]
        var previousDay = Calendar.current.startOfDay(for: Date())
        for snapshot in sessions {
            let day = Calendar.current.startOfDay(for: snapshot.metadata.startedAt)
            if day != previousDay {
                let heading = Calendar.current.isDateInYesterday(day) ? "Yesterday" : day.formatted(date: .abbreviated, time: .omitted)
                sidebarItems.append(.heading(heading))
                previousDay = day
            }
            sidebarItems.append(.session(snapshot))
        }
        sidebar.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sidebarItems.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .heading = sidebarItems[row] { return 30 }
        return 60
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .heading = sidebarItems[row] { return false }
        return true
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SessionSelectionRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch sidebarItems[row] {
        case .heading(let title):
            let view = ConsolePanel()
            view.color = ConsoleTheme.sidebar
            let label = ConsoleTheme.label(title, size: 11, color: ConsoleTheme.tertiary)
            label.frame = NSRect(x: 12, y: 7, width: 180, height: 17)
            view.addSubview(label)
            return view
        case .session(let snapshot):
            let cell = SessionCell(frame: .zero)
            configure(cell, snapshot: snapshot ?? latest?.snapshot, live: snapshot == nil)
            return cell
        }
    }
    private func configure(_ cell: SessionCell, snapshot: SessionSnapshot?, live: Bool) {
        cell.title.stringValue = snapshot?.metadata.startedAt.formatted(date: .omitted, time: .shortened) ?? "Current session"
        cell.mark.stringValue = live ? "●" : ""
        cell.icon.isHidden = live
        cell.mark.textColor = live ? (latest?.device == nil ? ConsoleTheme.warningText : ConsoleTheme.green) : ConsoleTheme.tertiary
        let bytes = formatBytes(snapshot?.byteCount ?? 0)
        if live { cell.detail.stringValue = "\(latest?.device == nil ? "Waiting" : "Live") · \(bytes)" }
        else if let snapshot {
            let seconds = max(0, Int((snapshot.metadata.endedAt ?? snapshot.metadata.startedAt).timeIntervalSince(snapshot.metadata.startedAt)))
            cell.detail.stringValue = "\(seconds / 60)m \(seconds % 60)s · \(bytes)"
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard workspace != nil, sidebarItems.indices.contains(sidebar.selectedRow),
              case .session(let saved) = sidebarItems[sidebar.selectedRow] else { return }
        activeSearchCancellation?.cancel()
        searchTask?.cancel()
        searchResult = nil
        searchTask = nil
        log.highlightedQuery = nil
        searchStatus.stringValue = ""
        paused = false
        pauseButton.title = "Pause Display"
        pauseButton.symbol = "pause"
        let row = sidebar.selectedRow
        viewingHistory = saved != nil
        if let snapshot = saved {
            searchStatus.stringValue = "Opening session…"
            log.clear(message: "Opening saved session…")
            historyQueue.async { [weak self] in
                let result = Result {
                    if let active = try ActiveCaptureStore(rootDirectory: self?.root ?? snapshot.directory.deletingLastPathComponent()).active(),
                       active.snapshot.metadata.id == snapshot.metadata.id { return active.snapshot }
                    return try SessionReader.loadSnapshot(directory: snapshot.directory)
                }
                DispatchQueue.main.async {
                    guard let self, self.viewingHistory, self.sidebar.selectedRow == row else { return }
                    do {
                        try self.log.show(result.get(), follow: true)
                        self.searchStatus.stringValue = ""
                        self.updateSessionHeading()
                        self.updateInspector()
                    } catch {
                        self.showError(error)
                        self.searchStatus.stringValue = "Could not open session"
                        self.log.clear(message: "Could not open this session.\n\(error.localizedDescription)")
                    }
                }
            }
        } else if let latest {
            do { try log.show(latest.snapshot, follow: true) } catch { showError(error) }
        }
        updateSessionHeading()
        updatePosition()
    }

    @objc private func focusSearch() {
        workspace.searchVisible = true
        workspace.layoutSubtreeIfNeeded()
        window.makeFirstResponder(searchField)
        refreshSearchCount()
    }
    @objc private func closeSearch() {
        activeSearchCancellation?.cancel()
        searchTask?.cancel()
        searchTask = nil
        workspace.searchVisible = false
        log.highlightedQuery = nil
        window.makeFirstResponder(log.canvas)
    }
    @objc private func toggleSidebar() { workspace.sidebarVisible.toggle() }
    @objc private func findNext() { search(backwards: false) }
    @objc private func findPrevious() { search(backwards: true) }
    private func refreshSearchCount() {
        guard workspace.searchVisible, searchTask == nil, let result = searchResult,
              searchField.stringValue == lastQuery, let snapshot = log.snapshot,
              result.directory == snapshot.directory, result.byteCount < snapshot.byteCount else { return }
        search(backwards: false, advance: false)
    }

    private func search(backwards: Bool, advance: Bool = true) {
        activeSearchCancellation?.cancel()
        searchTask?.cancel()
        searchTask = nil
        let query = searchField.stringValue
        log.highlightedQuery = query.isEmpty ? nil : query
        if query != lastQuery { searchResult = nil; lastQuery = query }
        guard !query.isEmpty, let reader = log.reader, let snapshot = log.snapshot else {
            searchStatus.stringValue = ""
            return
        }
        guard query.utf8.count <= 65536 else { searchStatus.stringValue = "Search text is too long"; return }
        let previous = searchResult
        if advance { searchStatus.stringValue = "Searching…" }
        let cancellation = SearchCancellation()
        // Counting and navigation stay off the UI thread; the result holds only
        // a count and one selected range, even when a log has millions of hits.
        let task = DispatchWorkItem { [weak self] in
            do {
                let result = try reader.search(Data(query.utf8), previous: previous, backwards: backwards,
                    advance: advance, snapshot: snapshot, isCancelled: { cancellation.isCancelled })
                DispatchQueue.main.async {
                    guard let self, self.log.snapshot?.directory == snapshot.directory,
                          self.searchField.stringValue == query, !cancellation.isCancelled else { return }
                    self.searchTask = nil
                    self.searchResult = result
                    let noun = result.total == 1 ? "match" : "matches"
                    self.searchStatus.stringValue = result.total == 0 ? "No matches" : "\(result.number) of \(result.total) \(noun)"
                    if let match = result.match, advance || previous?.match != match {
                        do { try self.log.reveal(match) } catch { self.showError(error) }
                    }
                    self.refreshSearchCount()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !cancellation.isCancelled, self.searchField.stringValue == query,
                          self.log.snapshot?.directory == snapshot.directory else { return }
                    self.searchTask = nil
                    self.searchStatus.stringValue = error.localizedDescription
                }
            }
        }
        activeSearchCancellation = cancellation
        searchTask = task
        searchQueue.async(execute: task)
    }
    private var activeSearchCancellation: SearchCancellation?

    @objc private func toggleInspector() { workspace.inspectorVisible.toggle(); updateInspector() }
    private func updateInspector() {
        guard workspace.inspectorVisible, let snapshot = log.snapshot else { return }
        inspector.update(snapshot)
        inspectorUpdatedAt = Date()
    }
    @objc private func openSessionsFolder() { NSWorkspace.shared.open(root) }
    private func showError(_ error: Error) { statusLabel.stringValue = error.localizedDescription; statusLabel.textColor = .systemRed }
    private func argument(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
    private func formatBytes(_ count: UInt64) -> String { count == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }

    private func savePreview(_ filename: String) throws {
        guard let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("benchmark-results/\(filename)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("Preview: \(url.path)")
    }

    /// Runs against temporary fixtures only; never discovers or opens the user's hardware.
    @MainActor private func runUISmokeTest() async {
        do {
            let writer = try SessionWriter(rootDirectory: smokeRoot)
            let sampleDevice = SerialDevice(path: "/dev/cu.usbmodem11101", vendorID: 0x2e8a, productID: 0x00b7,
                manufacturer: "B4", product: "B4 PICO Ultra", serialNumber: "99EA21A8E17CD666", interfaceNumber: 1)
            try writer.beginSegment(device: sampleDevice)
            let sampleLines = ["boot-args: -v wdt=-1 rd=md0 serial=3", "Darwin kernel initializing",
                "AppleARMPlatform: platform initialization", "IOKit: matching platform services",
                "AppleSEPManager: starting services", "AppleCredentialManager: service initialized",
                "IOUSBHostFamily: device enumeration", "USB serial console active", "",
                "launchd: system bootstrap in progress", "kernel: waiting for root device", "kernel: root device available",
                "AppleMobileFileIntegrity: loading policy", "AppleCredentialManager: request received",
                "AppleCredentialManager: request completed", "", "IOKit: service matching complete",
                "launchd: starting system daemons", "system: entering user space",
                "AppleCredentialManager: request received", "AppleCredentialManager: request completed", "",
                "Console stream active", "Waiting for additional serial output…"]
            for _ in 0..<6 { try writer.append(Data((sampleLines.joined(separator: "\n") + "\n").utf8)) }
            received(CaptureUpdate(snapshot: writer.snapshot, status: "Synthetic capture", device: sampleDevice, isError: false))
            let before = log.snapshot!.byteCount
            togglePause()
            try writer.append(Data("New bytes while display is paused\n".utf8))
            received(CaptureUpdate(snapshot: writer.snapshot, status: "Synthetic capture", device: sampleDevice, isError: false))
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
                        log.canvas.scrollToRow(UInt64(row))
                        log.canvas.layoutSubtreeIfNeeded()
                        log.canvas.displayIfNeeded()
                    }
                }
                if CommandLine.arguments.contains("--paced-scroll") {
                    // Let AppKit present each frame, as it does between input events.
                    try await Task.sleep(nanoseconds: 16_666_667)
                }
            }
            log.jumpToLatest()
            window.contentView?.layoutSubtreeIfNeeded()
            precondition(log.view.bounds.height > 200, "Log view must have usable height")
            precondition(log.view.bounds.width > 300, "Log view must have usable width")
            print("UI smoke passed: pause, resume, 100 scroll positions, layout")
            print("Visible log size: \(log.view.bounds.size)")
            if CommandLine.arguments.contains("--wrapped-log-smoke") {
                let wrapped = try WrappedLogSmoke.run(log: log, window: window, root: smokeRoot)
                latest = CaptureUpdate(snapshot: wrapped, status: "Synthetic capture", device: sampleDevice, isError: false)
                updateSessionHeading()
            }
            if !CommandLine.arguments.contains("--no-snapshot") {
                let state = argument("--preview-state") ?? "live"
                let appearance = argument("--appearance") ?? (CommandLine.arguments.contains("dark") ? "dark" : "light")
                window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                if CommandLine.arguments.contains("--toggle-theme") {
                    let bytes = log.snapshot?.byteCount
                    workspace.themeButton.performClick(nil)
                    precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) !=
                                 (appearance == "dark" ? NSAppearance.Name.darkAqua : .aqua))
                    precondition(log.snapshot?.byteCount == bytes, "Changing theme must preserve the displayed session")
                }
                if CommandLine.arguments.contains("--compact") { window.setContentSize(NSSize(width: 960, height: 600)) }
                // Preview fixtures are synthetic and never discover or open a real serial port.
                for hours in [1, 3, 12, 17] {
                    let history = try SessionWriter(rootDirectory: smokeRoot)
                    try history.append(Data((sampleLines.joined(separator: "\n") + "\n").utf8))
                    try history.finish()
                    var saved = history.snapshot
                    saved.metadata.startedAt = Date().addingTimeInterval(-Double(hours * 3600))
                    saved.metadata.endedAt = saved.metadata.startedAt.addingTimeInterval(1122)
                    try JSONEncoder().encode(saved.metadata).write(to: saved.directory.appendingPathComponent("metadata.json"))
                    sessions.append(saved)
                }
                rebuildSidebar()
                sidebar.selectRowIndexes(IndexSet(integer: liveRow), byExtendingSelection: false)
                if state == "paused" { togglePause() }
                if state == "inspector" { toggleInspector() }
                if state == "search" {
                    focusSearch()
                    searchField.stringValue = "AppleCredentialManager"
                    findNext()
                    let deadline = Date().addingTimeInterval(3)
                    while searchTask != nil && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
                    precondition(searchStatus.stringValue == "1 of 30 matches", "Search must display the current hit and total")
                    findPrevious()
                    while searchTask != nil && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
                    precondition(searchStatus.stringValue == "30 of 30 matches", "Previous must wrap to the last numbered hit")
                    findNext()
                    while searchTask != nil && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
                    precondition(searchStatus.stringValue == "1 of 30 matches", "Next must wrap to the first numbered hit")
                    precondition(NSApp.target(forAction: #selector(NSText.paste(_:))) != nil,
                                 "Paste must resolve to the focused search field's native editor")
                    let pasteItem = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }
                        .first { $0.action == #selector(NSText.paste(_:)) }
                    precondition(pasteItem?.keyEquivalent == "v" && pasteItem?.keyEquivalentModifierMask.contains(.command) == true,
                                 "The Edit menu must register Command-V for Paste")
                    print("Search smoke passed: match count, next/previous wrap, native Paste target")
                }
                if state == "history" {
                    sidebar.selectRowIndexes(IndexSet(integer: sidebarItems.count - 1), byExtendingSelection: false)
                    let deadline = Date().addingTimeInterval(2)
                    while log.snapshot?.directory != sessions.last?.directory && Date() < deadline {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    precondition(viewingHistory && log.snapshot?.directory == sessions.last?.directory,
                                 "Selecting a grouped history row must load that saved session")
                    precondition(jumpButton.superview === workspace.sessionHeader && pauseButton.isHidden && !workspace.messageVisible,
                                 "History must put Return to Live in the header without a duplicate banner")
                }
                if state == "disconnected" {
                    received(CaptureUpdate(snapshot: writer.snapshot, status: "Interface disconnected", device: nil, isError: false))
                }
                if state == "waiting" {
                    let empty = try SessionWriter(rootDirectory: smokeRoot)
                    received(CaptureUpdate(snapshot: empty.snapshot, status: "Waiting for interface", device: nil, isError: false))
                    try empty.finish()
                }
                workspace.layoutSubtreeIfNeeded()
                if state == "settings" {
                    var second = sampleDevice
                    second.path = "/dev/cu.usbmodem11201"; second.serialNumber = "99EA21A8E17C8F2A"
                    picker.update(devices: [sampleDevice, second], selectedID: sampleDevice.stableID,
                                  activeID: sampleDevice.stableID, error: nil)
                    // Render the same picker view in the window for a deterministic component preview.
                    workspace.addSubview(picker)
                    picker.frame = NSRect(x: workspace.bounds.width - 465, y: 56, width: 340, height: 250)
                }
                workspace.layoutSubtreeIfNeeded()
                if state == "wrapped" {
                    log.canvas.scrollToRow(0)
                    if let point = log.canvas.point(for: LogPosition(row: 0, column: 6)) {
                        log.canvas.beginSelection(at: point, extending: false, clicks: 2)
                    }
                }
                let filename = "UI-\(appearance)-\(state)\(CommandLine.arguments.contains("--toggle-theme") ? "-toggled" : "")\(CommandLine.arguments.contains("--compact") ? "-compact" : "").png"
                try savePreview(filename)
                if state == "history" {
                    jumpButton.performClick(nil)
                    precondition(!viewingHistory && log.snapshot?.directory == latest?.snapshot.directory,
                                 "Return to Live must restore the active session")
                    precondition(jumpButton.superview === workspace.messageBar && !pauseButton.isHidden && !jumpButton.accented,
                                 "Returning to live must restore the normal header and Jump to Latest banner action")
                    print("History smoke passed: grouped selection, background load, return to live")
                }
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
