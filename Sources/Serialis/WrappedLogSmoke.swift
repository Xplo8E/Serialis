import AppKit
import SerialisCore

/// Temporary text fixtures exercise actual layout/hit testing, without serial hardware.
enum WrappedLogSmoke {
    static func run(log: LogViewController, window: NSWindow, root: URL) throws -> SessionSnapshot {
        func check(_ condition: Bool, _ message: String = "Wrapped log check failed") {
            precondition(condition, message)
        }
        let writer = try SessionWriter(rootDirectory: root)
        let longLine = "IOKit: " + String(repeating: "device-service-state=ready ", count: 70) + "end-marker"
        let unicode = "Unicode: café 😀 e\u{301} 你好\tend"
        try writer.append(Data("alpha bravo charlie\n\(longLine)\n\(unicode)\nnew choice\n".utf8))
        try writer.finish()
        try log.show(writer.snapshot, follow: false)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        log.canvas.viewportResized()
        log.canvas.scrollToRow(0)
        let wideHeight = log.canvas.height(of: 1)!
        window.setContentSize(NSSize(width: 960, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        log.canvas.viewportResized()
        log.canvas.scrollToRow(0)
        check(log.canvas.height(of: 1)! > wideHeight, "Narrowing the window must wrap long text into more visual lines")
        check(!log.scroll.hasHorizontalScroller && log.canvas.bounds.width == log.scroll.contentSize.width)
        check(log.canvas.cachedRowCount <= 256, "Text layouts must remain bounded")

        func select(_ start: LogPosition, _ end: LogPosition) {
            log.canvas.scrollToRow(start.row)
            log.canvas.beginSelection(at: log.canvas.point(for: start)!, extending: false)
            log.canvas.extendSelection(at: log.canvas.point(for: end)!)
        }
        func selectedText() throws -> String {
            guard let range = try log.canvas.selectedByteRange(), let reader = log.reader else { return "" }
            return String(decoding: try reader.readBytes(in: range), as: UTF8.self)
        }

        select(LogPosition(row: 0, column: 6), LogPosition(row: 0, column: 11))
        check(try selectedText() == "bravo", "Dragging inside one line must select only those characters")
        let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let copyItem = log.canvas.menu(for: rightClick)?.item(withTitle: "Copy")
        check(copyItem?.isEnabled == true && copyItem?.target === log.canvas,
              "The log context menu must offer Copy for selected text")
        check(try selectedText() == "bravo", "Opening the context menu must preserve the selection")
        // Reflow must keep the original bytes selected, not the previous visual row number.
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        log.canvas.viewportResized()
        check(try selectedText() == "bravo")

        log.canvas.scrollToRow(3)
        log.canvas.beginSelection(at: log.canvas.point(for: LogPosition(row: 3, column: 4))!, extending: false)
        check(log.canvas.selection == nil && log.canvas.caret?.row == 3, "A plain click must replace the old selection")
        check(log.canvas.menu(for: rightClick)?.item(withTitle: "Copy")?.isEnabled == false,
              "Context Copy must be disabled without selected text")
        log.canvas.moveRightAndModifySelection(nil)
        check(try selectedText() == "c", "Shift-arrow must extend the caret by one character")

        select(LogPosition(row: 0, column: 6), LogPosition(row: 1, column: 5))
        check(try selectedText() == "bravo charlie\nIOKit", "Selection across source lines must retain only original newlines")
        // The selected source range crosses several soft wraps without gaining newlines.
        select(LogPosition(row: 1, column: 5), LogPosition(row: 1, column: 200))
        check(try selectedText() == (longLine as NSString).substring(with: NSRange(location: 5, length: 195)))
        let emoji = (unicode as NSString).range(of: "😀")
        select(LogPosition(row: 2, column: emoji.location), LogPosition(row: 2, column: NSMaxRange(emoji)))
        check(try selectedText() == "😀", "Selection must map UTF-16 hit testing to complete UTF-8 bytes")
        log.canvas.selectAll(nil)
        check(try log.canvas.selectedByteRange() == 0..<writer.snapshot.byteCount, "Select All includes the final raw newline")

        log.jumpToLatest()
        window.setContentSize(NSSize(width: 1280, height: 550))
        window.contentView?.layoutSubtreeIfNeeded()
        log.canvas.viewportResized()
        check(log.scroll.contentView.bounds.maxY >= log.canvas.documentHeight - 1, "Height-only resize must keep the latest text visible")

        let beforeZoom = window.frame
        let topBar = (window.contentView as! ConsoleWorkspace).topBar
        let doubleClick = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        topBar.mouseDown(with: doubleClick)
        window.contentView?.layoutSubtreeIfNeeded()
        check(window.frame != beforeZoom, "Zoom must expand the window")
        topBar.mouseDown(with: doubleClick)
        check(abs(window.frame.width - beforeZoom.width) < 1 && abs(window.frame.height - beforeZoom.height) < 1,
                     "Zoom must restore the previous window size")
        log.canvas.scrollToRow(0)
        log.canvas.beginSelection(at: log.canvas.point(for: LogPosition(row: 0, column: 6))!, extending: false, clicks: 2)
        check(try selectedText() == "bravo", "Double-click selects a word")
        log.canvas.beginSelection(at: log.canvas.point(for: LogPosition(row: 0, column: 6))!, extending: false, clicks: 3)
        check(try selectedText() == "alpha bravo charlie\n", "Triple-click includes the original line ending")
        print("Wrapped UI passed: resize/reflow, partial text, replacement click, Shift-arrow, multiline/emoji copy, Select All, zoom/restore")
        return writer.snapshot
    }
}
