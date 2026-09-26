import AppKit
import SerialisCore

struct LogPosition: Comparable {
    let row: UInt64
    let column: Int
    static func < (left: Self, right: Self) -> Bool {
        left.row == right.row ? left.column < right.column : left.row < right.row
    }
}

/// Only the viewport and a small margin have text layouts. Offscreen source rows use
/// an estimated height, so resizing never scans or loads the entire capture.
final class WrappedLogView: NSView {
    static let lineHeight: CGFloat = 24
    static let textInset: CGFloat = 78
    var onPositionChange: (() -> Void)?
    var onCopy: (() -> Void)?
    var onError: ((Error) -> Void)?
    var query: String? { didSet { refresh() } }
    private(set) var followsLatest = true
    private(set) var anchor: LogPosition?
    private(set) var caret: LogPosition?
    private(set) var snapshot: SessionSnapshot?
    private var reader: SessionReader?
    private var rows: [WrappedLogRow] = []
    private var updating = false
    private var layoutWidth: CGFloat = 0
    private var layoutHeight: CGFloat = 0
    private var observer: NSObjectProtocol?
    private var dragEvent: NSEvent?
    private var dragTimer: Timer?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    var selection: (start: LogPosition, end: LogPosition)? {
        guard let anchor, let caret, anchor != caret else { return nil }
        return (min(anchor, caret), max(anchor, caret))
    }

    func observeScrolling() {
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: clip, queue: .main) { [weak self] _ in self?.scrolled() }
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Serial log")
    }

    func show(_ next: SessionSnapshot, reader: SessionReader, follow: Bool?) throws {
        let changed = snapshot?.directory != next.directory
        let oldTop = topAnchor()
        snapshot = next
        self.reader = reader
        if changed { anchor = nil; caret = nil; followsLatest = true; rows = [] }
        if let follow { followsLatest = follow }
        if followsLatest { try positionAtEnd() }
        else { try rebuild(around: oldTop.row, offset: oldTop.offset) }
    }

    func clear() {
        snapshot = nil; reader = nil; rows = []; anchor = nil; caret = nil
        setDocumentSize(enclosingScrollView?.contentSize ?? .zero)
        needsDisplay = true
    }

    func viewportResized() {
        guard !updating, let size = enclosingScrollView?.contentSize,
              abs(size.width - layoutWidth) > 0.5 || abs(size.height - layoutHeight) > 0.5 else { return }
        refresh()
    }

    func jumpToLatest() {
        anchor = nil; caret = nil; followsLatest = true
        do { try positionAtEnd() } catch { onError?(error) }
        onPositionChange?()
    }

    func scrollToRow(_ row: UInt64) {
        followsLatest = false
        do { try rebuild(around: row, offset: 0) } catch { onError?(error) }
        onPositionChange?()
    }

    func reveal(_ match: Range<UInt64>) throws {
        guard let reader, let snapshot, !match.isEmpty else { return }
        let first = try reader.row(containing: match.lowerBound, snapshot: snapshot)
        let last = try reader.row(containing: match.upperBound - 1, snapshot: snapshot)
        let firstData = try reader.readRow(first, snapshot: snapshot)
        let lastData = try reader.readRow(last, snapshot: snapshot)
        anchor = LogPosition(row: first, column: DisplayText(data: firstData.data)
            .utf16Index(forByteOffset: Int(match.lowerBound - firstData.offset)))
        caret = LogPosition(row: last, column: DisplayText(data: lastData.data)
            .utf16Index(forByteOffset: Int(match.upperBound - lastData.offset)))
        followsLatest = false
        try rebuild(around: first, offset: 0)
        if let line = rows.first(where: { $0.index == first }), let anchor {
            scroll(toY: line.y + line.caretRect(anchor.column).minY)
        }
        onPositionChange?()
    }

    func selectedByteRange() throws -> Range<UInt64>? {
        guard let selection, let reader, let snapshot else { return nil }
        func offset(_ position: LogPosition) throws -> UInt64 {
            let row = try reader.readRow(position.row, snapshot: snapshot)
            let display = DisplayText(data: row.data)
            let offset = position.column > display.text.utf16.count ? row.data.count : display.byteOffset(forUTF16Index: position.column)
            return row.offset + UInt64(offset)
        }
        return try offset(selection.start)..<offset(selection.end)
    }

    private func positionAtEnd() throws {
        guard let snapshot, snapshot.rowCount > 0 else {
            rows = []; setDocumentSize(enclosingScrollView?.contentSize ?? .zero); needsDisplay = true; return
        }
        try rebuild(around: snapshot.rowCount - 1, offset: 0, bottom: true)
    }

    private func refresh() {
        guard reader != nil else { return }
        let top = topAnchor()
        do {
            if followsLatest { try positionAtEnd() }
            else { try rebuild(around: top.row, offset: top.offset) }
        } catch { onError?(error) }
    }

    private func topAnchor() -> (row: UInt64, offset: CGFloat) {
        let y = enclosingScrollView?.contentView.bounds.minY ?? 0
        if let row = rows.first(where: { y >= $0.y && y < $0.y + $0.height }) { return (row.index, y - row.y) }
        if let last = rows.last, y >= last.y + last.height {
            return (last.index + 1 + UInt64(max(0, (y - last.y - last.height) / Self.lineHeight)), 0)
        }
        return (UInt64(max(0, y / Self.lineHeight)), 0)
    }

    private func scrolled() {
        guard !updating, let scroll = enclosingScrollView else { return }
        updateCanvasFrame()
        followsLatest = selection == nil && scroll.contentView.bounds.maxY >= documentHeight - 1
        let visible = scroll.contentView.bounds
        // Reuse current layouts during ordinary wheel scrolling.
        if rows.first.map({ visible.minY < $0.y }) ?? true || rows.last.map({ visible.maxY > $0.y + $0.height }) ?? true {
            let top = topAnchor()
            do { try rebuild(around: top.row, offset: top.offset) } catch { onError?(error) }
        }
        needsDisplay = true
        onPositionChange?()
    }

    private func rebuild(around requested: UInt64, offset: CGFloat, bottom: Bool = false) throws {
        guard !updating, let snapshot, let reader, let scroll = enclosingScrollView else { return }
        updating = true
        defer { updating = false }
        layoutWidth = max(120, scroll.contentSize.width)
        let viewportHeight = max(24, scroll.contentSize.height)
        layoutHeight = scroll.contentSize.height
        guard snapshot.rowCount > 0 else {
            rows = []; setDocumentSize(NSSize(width: layoutWidth, height: viewportHeight)); needsDisplay = true; return
        }
        let target = min(requested, snapshot.rowCount - 1)
        let width = max(20, layoutWidth - Self.textInset - 16)
        // Reuse native layout objects while scrolling. Creating a new TextKit stack
        // for every row visited makes framework allocation caches grow needlessly.
        var reusable = rows
        func load(_ index: UInt64) throws -> WrappedLogRow {
            let raw = try reader.readRow(index, snapshot: snapshot)
            let row = reusable.popLast() ?? WrappedLogRow()
            row.update(index: index, data: raw.data, width: width, query: query)
            return row
        }
        var loaded = [try load(target)]
        var bytes = loaded[0].byteCount
        var before: CGFloat = 0
        var index = target
        // Bound both the number of native layouts and their decoded input.
        while index > 0 && before < viewportHeight + 96 && loaded.count < 256 && bytes < 262144 {
            index -= 1
            let row = try load(index)
            loaded.insert(row, at: 0); before += row.height; bytes += row.byteCount
        }
        let targetOffset = min(max(0, offset), loaded.last!.height - 1)
        var after = loaded.last!.height
        index = target + 1
        while index < snapshot.rowCount && after < targetOffset + viewportHeight + 96 && loaded.count < 256 && bytes < 262144 {
            let row = try load(index)
            loaded.append(row); after += row.height; bytes += row.byteCount; index += 1
        }
        var y = CGFloat(loaded[0].index) * Self.lineHeight
        for row in loaded { row.y = y; y += row.height }
        rows = loaded
        let height = max(viewportHeight, y + CGFloat(snapshot.rowCount - index) * Self.lineHeight)
        setDocumentSize(NSSize(width: layoutWidth, height: height))
        let targetY = rows.first(where: { $0.index == target })!.y + targetOffset
        self.scroll(toY: bottom ? height - viewportHeight : targetY)
        needsDisplay = true
    }

    private func scroll(toY y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, documentHeight - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        updateCanvasFrame()
    }

    var documentHeight: CGFloat { enclosingScrollView?.documentView?.bounds.height ?? 0 }

    private func setDocumentSize(_ size: NSSize) {
        enclosingScrollView?.documentView?.setFrameSize(size)
        updateCanvasFrame()
    }

    private func updateCanvasFrame() {
        guard let clip = enclosingScrollView?.contentView else { return }
        // Keep drawing coordinates in document space while the backing surface
        // remains the size of the viewport, even for multi-gigabyte sessions.
        frame = clip.bounds
        bounds.origin = clip.bounds.origin
    }

    override func draw(_ dirtyRect: NSRect) {
        ConsoleTheme.background.setFill(); dirtyRect.fill()
        ConsoleTheme.gutter.setFill(); dirtyRect.intersection(NSRect(x: 0, y: dirtyRect.minY, width: 62, height: dirtyRect.height)).fill()
        ConsoleTheme.border.setFill(); NSRect(x: 61, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        let numberStyle = NSMutableParagraphStyle()
        numberStyle.minimumLineHeight = 24; numberStyle.maximumLineHeight = 24
        numberStyle.alignment = .right
        for row in rows where row.y < dirtyRect.maxY && row.y + row.height > dirtyRect.minY {
            let origin = NSPoint(x: Self.textInset, y: row.y)
            row.draw(at: origin, selection: selection)
            let number = String(row.index + 1) as NSString
            let numberFont = number.length > 7 ? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular) : WrappedLogRow.font
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont,
                .foregroundColor: ConsoleTheme.tertiary, .paragraphStyle: numberStyle]
            number.draw(in: NSRect(x: 0, y: row.y, width: 54, height: 24), withAttributes: attributes)
            if selection == nil, caret?.row == row.index, let caret, window?.firstResponder === self {
                ConsoleTheme.text.setFill(); row.caretRect(caret.column).offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .iBeam) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginSelection(at: convert(event.locationInWindow, from: nil), extending: event.modifierFlags.contains(.shift), clicks: event.clickCount)
    }

    // Also exercised by the UI smoke check, using real TextKit hit testing.
    func beginSelection(at point: NSPoint, extending: Bool, clicks: Int = 1) {
        guard let position = position(at: point) else { return }
        followsLatest = false
        if !extending || anchor == nil { anchor = position }
        caret = position
        if clicks >= 2, let row = rows.first(where: { $0.index == position.row }) {
            // The extra endpoint includes the original newline when copying a whole line.
            let range = clicks >= 3 ? NSRange(location: 0, length: row.text.length + 1) : row.wordRange(at: position.column)
            anchor = LogPosition(row: position.row, column: range.location)
            caret = LogPosition(row: position.row, column: NSMaxRange(range))
        }
        needsDisplay = true; onPositionChange?()
    }

    override func mouseDragged(with event: NSEvent) {
        dragEvent = event
        extendSelection(at: convert(event.locationInWindow, from: nil))
        if dragTimer == nil {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.dragScroll() }
            dragTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func extendSelection(at point: NSPoint) {
        if let position = position(at: point) { caret = position; followsLatest = false; needsDisplay = true; onPositionChange?() }
    }
    override func mouseUp(with event: NSEvent) { dragTimer?.invalidate(); dragTimer = nil; dragEvent = nil }
    private func dragScroll() {
        guard let event = dragEvent else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.y < visibleRect.minY { scroll(toY: visibleRect.minY - 24) }
        if point.y > visibleRect.maxY { scroll(toY: visibleRect.minY + 24) }
        extendSelection(at: convert(event.locationInWindow, from: nil))
    }

    private func position(at point: NSPoint) -> LogPosition? {
        guard let first = rows.first, let last = rows.last else { return nil }
        let row = rows.first(where: { point.y < $0.y + $0.height }) ?? last
        if point.y < first.y { return LogPosition(row: first.index, column: 0) }
        return LogPosition(row: row.index, column: row.character(at: NSPoint(x: point.x - Self.textInset, y: point.y - row.y)))
    }

    @objc func copy(_ sender: Any?) { onCopy?() }
    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copy = menu.addItem(withTitle: "Copy", action: #selector(WrappedLogView.copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = selection != nil
        let selectAll = menu.addItem(withTitle: "Select All", action: #selector(WrappedLogView.selectAll(_:)), keyEquivalent: "")
        selectAll.target = self
        selectAll.isEnabled = (snapshot?.rowCount ?? 0) > 0
        return menu
    }
    override func selectAll(_ sender: Any?) {
        guard let snapshot, snapshot.rowCount > 0, let reader else { return }
        do {
            let last = try reader.readRow(snapshot.rowCount - 1, snapshot: snapshot)
            anchor = LogPosition(row: 0, column: 0)
            // Include the final row's original newline when selecting the full session.
            caret = LogPosition(row: snapshot.rowCount - 1, column: DisplayText(data: last.data).text.utf16.count + 1)
            followsLatest = false; needsDisplay = true; onPositionChange?()
        } catch { onError?(error) }
    }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func moveLeft(_ sender: Any?) { move(horizontal: -1, extending: false) }
    override func moveRight(_ sender: Any?) { move(horizontal: 1, extending: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { move(horizontal: -1, extending: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { move(horizontal: 1, extending: true) }
    override func moveUp(_ sender: Any?) { moveVertical(-24, extending: false) }
    override func moveDown(_ sender: Any?) { moveVertical(24, extending: false) }
    override func moveUpAndModifySelection(_ sender: Any?) { moveVertical(-24, extending: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { moveVertical(24, extending: true) }

    private func move(horizontal: Int, extending: Bool) {
        guard let snapshot, let reader, var position = caret else { return }
        do {
            let raw = try reader.readRow(position.row, snapshot: snapshot)
            let text = DisplayText(data: raw.data).text as NSString
            let column = min(position.column, text.length)
            if horizontal < 0 {
                if column > 0 { position = LogPosition(row: position.row, column: text.rangeOfComposedCharacterSequence(at: column - 1).location) }
                else if position.row > 0 {
                    let previous = try reader.readRow(position.row - 1, snapshot: snapshot)
                    position = LogPosition(row: position.row - 1, column: DisplayText(data: previous.data).text.utf16.count)
                }
            } else if column < text.length {
                position = LogPosition(row: position.row, column: NSMaxRange(text.rangeOfComposedCharacterSequence(at: column)))
            } else if position.row + 1 < snapshot.rowCount { position = LogPosition(row: position.row + 1, column: 0) }
            if !extending { anchor = position }
            caret = position; followsLatest = false
            if !rows.contains(where: { $0.index == position.row }) { try rebuild(around: position.row, offset: 0) }
            scrollCaretIntoView(position)
            needsDisplay = true; onPositionChange?()
        } catch { onError?(error) }
    }
    private func moveVertical(_ dy: CGFloat, extending: Bool) {
        guard let caret, let row = rows.first(where: { $0.index == caret.row }) else { return }
        let rect = row.caretRect(caret.column)
        let point = NSPoint(x: Self.textInset + rect.minX, y: row.y + rect.midY + dy)
        if let position = position(at: point) {
            if !extending { anchor = position }
            self.caret = position; followsLatest = false; needsDisplay = true
            scrollCaretIntoView(position)
            onPositionChange?()
        }
    }

    private func scrollCaretIntoView(_ position: LogPosition) {
        guard let row = rows.first(where: { $0.index == position.row }), let clip = enclosingScrollView?.contentView else { return }
        let rect = row.caretRect(position.column).offsetBy(dx: Self.textInset, dy: row.y)
        if rect.minY < clip.bounds.minY { scroll(toY: rect.minY) }
        else if rect.maxY > clip.bounds.maxY { scroll(toY: rect.maxY - clip.bounds.height) }
    }

    // Geometry helpers keep regression checks independent of guessed screen coordinates.
    func point(for position: LogPosition) -> NSPoint? {
        guard let row = rows.first(where: { $0.index == position.row }) else { return nil }
        let rect = row.caretRect(position.column)
        return NSPoint(x: Self.textInset + rect.minX, y: row.y + rect.midY)
    }
    func height(of row: UInt64) -> CGFloat? { rows.first(where: { $0.index == row })?.height }
    var cachedRowCount: Int { rows.count }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; dragTimer?.invalidate() }
}

private final class WrappedLogRow {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private(set) var index: UInt64 = 0
    private(set) var byteCount: Int = 0
    private(set) var text: NSString = ""
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
    private(set) var height: CGFloat = 24
    var y: CGFloat = 0

    init() {
        container.lineFragmentPadding = 0
        layout.usesFontLeading = false
        storage.addLayoutManager(layout); layout.addTextContainer(container)
    }

    func update(index: UInt64, data: Data, width: CGFloat, query: String?) {
        self.index = index; byteCount = data.count
        text = DisplayText(data: data).text as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 24; paragraph.maximumLineHeight = 24
        paragraph.lineBreakMode = .byWordWrapping
        storage.setAttributedString(NSAttributedString(string: text as String, attributes: [.font: Self.font,
            .foregroundColor: ConsoleTheme.text, .paragraphStyle: paragraph]))
        if let query, !query.isEmpty {
            var start = 0
            while start < text.length {
                let match = text.range(of: query, range: NSRange(location: start, length: text.length - start))
                if match.location == NSNotFound { break }
                storage.addAttribute(.backgroundColor, value: ConsoleTheme.searchHighlight, range: match)
                start = NSMaxRange(match)
            }
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        height = max(24, ceil(layout.usedRect(for: container).height))
    }

    func character(at point: NSPoint) -> Int {
        guard text.length > 0 else { return 0 }
        var fraction: CGFloat = 0
        let index = min(text.length, layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction))
        guard index < text.length else { return text.length }
        let composed = text.rangeOfComposedCharacterSequence(at: index)
        return fraction > 0.5 ? NSMaxRange(composed) : composed.location
    }

    func caretRect(_ column: Int) -> NSRect {
        guard text.length > 0 else { return NSRect(x: 0, y: 0, width: 1, height: 24) }
        let index = min(max(0, column), text.length)
        let glyph = layout.glyphIndexForCharacter(at: min(index, text.length - 1))
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var x = layout.location(forGlyphAt: glyph).x
        if index == text.length { x = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX }
        return NSRect(x: x, y: line.minY, width: 1, height: 24)
    }

    func wordRange(at column: Int) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let index = min(column, text.length - 1)
        var result = text.rangeOfComposedCharacterSequence(at: index)
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            if NSLocationInRange(index, range) { result = range; stop.pointee = true }
        }
        return result
    }

    func draw(at origin: NSPoint, selection: (start: LogPosition, end: LogPosition)?) {
        let glyphs = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: glyphs, at: origin)
        if let selection, index >= selection.start.row, index <= selection.end.row {
            let start = index == selection.start.row ? min(selection.start.column, text.length) : 0
            let end = index == selection.end.row ? min(selection.end.column, text.length) : text.length
            if end > start {
                let selected = layout.glyphRange(forCharacterRange: NSRange(location: start, length: end - start), actualCharacterRange: nil)
                ConsoleTheme.selection.setFill()
                layout.enumerateEnclosingRects(forGlyphRange: selected, withinSelectedGlyphRange: selected, in: container) { rect, _ in
                    rect.offsetBy(dx: origin.x, dy: origin.y).fill()
                }
            }
        }
        layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
}
