import AppKit

/// Colors and measurements taken from the approved Figma console screens.
enum ConsoleTheme {
    static let background = color(0xFFFFFF, 0x17191D)
    static let chrome = color(0xF4F4F6, 0x202227)
    static let sidebar = color(0xF1F2F4, 0x202227)
    static let gutter = color(0xFAFBFC, 0x181B20)
    static let border = color(0xDADDE2, 0x34373E)
    static let text = color(0x252A33, 0xE9ECF1)
    static let secondary = color(0x6B7380, 0x9AA1AC)
    static let tertiary = color(0x9299A5, 0x69717D)
    static let selection = color(0xDCEAFF, 0x253E62)
    static let accent = color(0x176DCC, 0x79B2FF)
    static let green = color(0x278552, 0x66C594)
    static let banner = color(0xEAF2FF, 0x24303F)
    static let pickerSelection = color(0xEAF2FF, 0x24303F)
    static let searchHighlight = color(0xFFF1A8, 0x5B4A16)
    static let warningText = color(0x9B6B25, 0xD8AC6E)
    static let warning = color(0xFFF4E4, 0x3A3024)

    static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
    }

    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor = ConsoleTheme.text) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

class ConsolePanel: NSView {
    var color: NSColor = ConsoleTheme.background
    var bottomBorder = false
    var rightBorder = false
    var draggable = false
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { draggable }
    override func mouseDown(with event: NSEvent) {
        // Our custom top bar must handle the native title bar's zoom gesture.
        if draggable, event.clickCount == 2 { window?.performZoom(nil) }
        else if draggable { window?.performDrag(with: event) }
        else { super.mouseDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); bounds.fill()
        ConsoleTheme.border.setFill()
        if bottomBorder { NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
        if rightBorder { NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Native button behavior, with the quiet flat treatment used in the design.
final class ConsoleButton: NSButton {
    var symbol: String? { didSet { needsDisplay = true } }
    var outlined = false
    var symbolAfterTitle = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(_ title: String = "", symbol: String? = nil) {
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = title
        font = .systemFont(ofSize: 12)
        isBordered = false
        setButtonType(.momentaryPushIn)
    }
    required init?(coder: NSCoder) { fatalError("Use init(title:symbol:)") }
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        if outlined || hovered || cell?.isHighlighted == true {
            (cell?.isHighlighted == true ? ConsoleTheme.selection : (hovered ? ConsoleTheme.sidebar : ConsoleTheme.background)).setFill()
            shape.fill()
        }
        if outlined { ConsoleTheme.border.setStroke(); shape.stroke() }
        let tint = isEnabled ? ConsoleTheme.secondary : ConsoleTheme.tertiary
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: tint]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let iconWidth: CGFloat = symbol == nil ? 0 : 16
        let gap: CGFloat = symbol == nil || title.isEmpty ? 0 : 7
        let x = (bounds.width - textSize.width - iconWidth - gap) / 2
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))?
            .withSymbolConfiguration(.init(paletteColors: [tint])) {
            let scale = min(16 / image.size.width, 16 / image.size.height)
            let iconSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let iconX = symbolAfterTitle ? x + textSize.width + gap : x
            image.draw(in: NSRect(x: iconX + (16 - iconSize.width) / 2, y: (bounds.height - iconSize.height) / 2,
                                 width: iconSize.width, height: iconSize.height),
                       from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5, respectFlipped: true, hints: nil)
        }
        (title as NSString).draw(at: NSPoint(x: symbolAfterTitle ? x : x + iconWidth + gap, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke(); shape.lineWidth = 2; shape.stroke()
        }
    }
}
