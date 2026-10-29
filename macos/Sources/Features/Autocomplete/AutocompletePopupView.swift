import AppKit

/// Slimer autocomplete popup: a custom-drawn subview of the surface view
/// (not a child window, no table view) so updating it per keystroke is cheap.
/// All strings are sanitized before drawing.
final class AutocompletePopupView: NSView {
    struct Palette {
        let background: NSColor
        let foreground: NSColor
        let selection: NSColor
        let dimmed: NSColor
        let border: NSColor
        let danger: NSColor

        /// Derive the popup colors from the terminal's background and
        /// foreground: a slightly lifted background, a translucent
        /// foreground selection, dimmed descriptions.
        init(background: NSColor, foreground: NSColor) {
            let bg = background.usingColorSpace(.sRGB) ?? background
            let fg = foreground.usingColorSpace(.sRGB) ?? foreground
            let dark = bg.brightnessComponent < 0.5
            self.background = bg.blended(withFraction: 0.08, of: dark ? .white : .black) ?? bg
            self.foreground = fg
            self.selection = fg.withAlphaComponent(0.16)
            self.dimmed = fg.withAlphaComponent(0.55)
            self.border = fg.withAlphaComponent(0.2)
            self.danger = .systemRed
        }
    }

    private struct Row {
        let icon: NSAttributedString
        let text: NSAttributedString
        let badge: NSAttributedString?
        let description: NSAttributedString?
    }

    private(set) var items: [AutocompleteItem] = []
    private(set) var selected: Int?
    private var rows: [Row] = []
    private var palette = Palette(background: .black, foreground: .white)
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    static let padding: CGFloat = 4
    static let rowPadding: CGFloat = 3
    static let maxWidth: CGFloat = 640
    static let descriptionGap: CGFloat = 16

    var rowHeight: CGFloat {
        ceil(font.ascender - font.descender + font.leading) + Self.rowPadding * 2
    }

    override var isFlipped: Bool { true }

    // The popup never takes keyboard focus or mouse clicks: keys go through
    // the surface view, which asks the controller first.
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        setAccessibilityRole(.list)
        setAccessibilityLabel("Autocomplete suggestions")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Replace the contents. Returns the size the popup wants.
    @discardableResult
    func update(
        items: [AutocompleteItem],
        selected: Int?,
        palette: Palette,
        fontSize: CGFloat
    ) -> NSSize {
        self.items = items
        self.selected = selected
        self.palette = palette
        let size = max(10, min(18, fontSize))
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        boldFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        layer?.backgroundColor = palette.background.cgColor
        layer?.borderColor = palette.border.cgColor
        rows = items.map(makeRow)
        needsDisplay = true
        return preferredSize
    }

    func select(_ index: Int?) {
        guard index != selected else { return }
        selected = index
        needsDisplay = true
    }

    var preferredSize: NSSize {
        var leftWidth: CGFloat = 0
        var descWidth: CGFloat = 0
        for row in rows {
            var w = row.icon.size().width + 6 + row.text.size().width
            if let badge = row.badge { w += 6 + badge.size().width }
            leftWidth = max(leftWidth, w)
            if let d = row.description { descWidth = max(descWidth, d.size().width) }
        }
        var width = Self.padding * 2 + leftWidth
        if descWidth > 0 { width += Self.descriptionGap + descWidth }
        width = min(Self.maxWidth, ceil(width) + 8)
        let height = Self.padding * 2 + CGFloat(rows.count) * rowHeight
        return NSSize(width: width, height: height)
    }

    private func makeRow(_ item: AutocompleteItem) -> Row {
        let display = AutocompleteText.sanitize(item.display)
        // Bolding uses byte offsets into the raw display; sanitizing only
        // replaces scalars 1:1 except for the length cap, so split the raw
        // display first and sanitize each half.
        let parts = AutocompleteText.splitMatched(item.display, matchLength: item.matchLength)
        let text = NSMutableAttributedString(
            string: AutocompleteText.sanitize(parts.matched),
            attributes: [.font: boldFont, .foregroundColor: palette.foreground]
        )
        let rest = parts.matched.isEmpty ? display : AutocompleteText.sanitize(parts.rest)
        text.append(NSAttributedString(
            string: rest,
            attributes: [.font: font, .foregroundColor: palette.foreground]
        ))
        let icon = NSAttributedString(
            string: item.kind.icon,
            attributes: [.font: font, .foregroundColor: palette.dimmed]
        )
        let badge = item.dangerous ? NSAttributedString(
            string: "⚠ dangerous",
            attributes: [.font: NSFont.systemFont(ofSize: font.pointSize - 2, weight: .semibold),
                         .foregroundColor: palette.danger]
        ) : nil
        let desc = AutocompleteText.sanitize(item.description)
        let description = desc.isEmpty ? nil : NSAttributedString(
            string: desc,
            attributes: [.font: font, .foregroundColor: palette.dimmed]
        )
        return Row(icon: icon, text: text, badge: badge, description: description)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rowHeight = self.rowHeight
        for (index, row) in rows.enumerated() {
            let y = Self.padding + CGFloat(index) * rowHeight
            let rowRect = NSRect(x: 2, y: y, width: bounds.width - 4, height: rowHeight)
            guard rowRect.intersects(dirtyRect) else { continue }
            if index == selected {
                palette.selection.setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 4, yRadius: 4).fill()
            }
            let baseline = y + Self.rowPadding
            var x = Self.padding + 2
            row.icon.draw(at: NSPoint(x: x, y: baseline))
            x += row.icon.size().width + 6
            let maxTextWidth = bounds.width - x - Self.padding
            row.text.draw(with: NSRect(x: x, y: baseline, width: maxTextWidth, height: rowHeight),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x += min(row.text.size().width, maxTextWidth)
            if let badge = row.badge {
                x += 6
                badge.draw(at: NSPoint(x: x, y: baseline + 1))
                x += badge.size().width
            }
            if let desc = row.description {
                let descWidth = desc.size().width
                let available = bounds.width - Self.padding - x - Self.descriptionGap
                guard available > 24 else { continue }
                let w = min(descWidth, available)
                let dx = bounds.width - Self.padding - w
                desc.draw(with: NSRect(x: dx, y: baseline, width: w, height: rowHeight),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
    }
}
