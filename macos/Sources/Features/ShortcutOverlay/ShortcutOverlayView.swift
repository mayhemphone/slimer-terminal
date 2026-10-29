import AppKit
import SwiftUI

/// Packs groups into columns that fit the window. Pure, so it can be tested.
enum ShortcutOverlayLayout {
    static let columnWidth: CGFloat = 270
    static let columnSpacing: CGFloat = 28
    static let rowHeight: CGFloat = 18
    static let padding: CGFloat = 20
    /// A group header costs this many rows (title plus the gap above it).
    static let headerRows = 2

    struct Result: Equatable {
        var columns: [[ShortcutGroup]]
        /// Entries that didn't fit, for the "and N more" footer.
        var hiddenCount: Int
    }

    /// The most rows a column can hold and the most columns that fit in `size`.
    static func capacity(for size: CGSize) -> (rows: Int, columns: Int) {
        let rows = Int((size.height - padding * 2 - rowHeight * 2) / rowHeight)
        let columns = Int((size.width - padding * 2 + columnSpacing) / (columnWidth + columnSpacing))
        return (max(rows, 6), max(columns, 1))
    }

    /// Fills columns top to bottom in group order. A group taller than the space left
    /// in a column is split, with "(cont.)" on the continued part. A group never starts
    /// with only its header at the bottom of a column.
    static func pack(_ groups: [ShortcutGroup], maxRows: Int, maxColumns: Int) -> Result {
        let maxRows = max(maxRows, headerRows + 1)
        var columns: [[ShortcutGroup]] = [[]]
        var used = 0

        for group in groups where !group.entries.isEmpty {
            var remaining = group.entries[...]
            var title = group.title
            while !remaining.isEmpty {
                if maxRows - used < headerRows + 1 {
                    columns.append([])
                    used = 0
                }
                let fit = min(remaining.count, maxRows - used - headerRows)
                columns[columns.count - 1].append(ShortcutGroup(title: title, entries: Array(remaining.prefix(fit))))
                used += headerRows + fit
                remaining = remaining.dropFirst(fit)
                title = "\(group.title) (cont.)"
            }
        }

        let visible = Array(columns.prefix(maxColumns))
        let hidden = columns.dropFirst(maxColumns).flatMap { $0 }.reduce(0) { $0 + $1.entries.count }
        return Result(columns: visible, hiddenCount: hidden)
    }
}

/// The sheet's content. Hosted in an `NSVisualEffectView` by the controller.
struct ShortcutOverlayView: View {
    let layout: ShortcutOverlayLayout.Result
    let holdHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: ShortcutOverlayLayout.columnSpacing) {
                ForEach(Array(layout.columns.enumerated()), id: \.offset) { _, column in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(column.enumerated()), id: \.offset) { index, group in
                            groupView(group, first: index == 0)
                        }
                    }
                    .frame(width: ShortcutOverlayLayout.columnWidth, alignment: .topLeading)
                }
            }
            HStack {
                if layout.hiddenCount > 0 {
                    Text("and \(layout.hiddenCount) more (make the window larger to see them)")
                }
                Spacer(minLength: 0)
                Text(holdHint)
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .padding(ShortcutOverlayLayout.padding)
        .fixedSize()
    }

    @ViewBuilder
    private func groupView(_ group: ShortcutGroup, first: Bool) -> some View {
        Text(group.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: ShortcutOverlayLayout.rowHeight, alignment: .bottomLeading)
            .padding(.top, first ? 0 : ShortcutOverlayLayout.rowHeight)
        ForEach(group.entries) { entry in
            row(entry)
        }
    }

    private func row(_ entry: ShortcutEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if entry.isGlobal {
                Text("Global")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(.secondary, lineWidth: 0.5))
                    .foregroundStyle(.secondary)
            }
            Text(entry.keys)
                .font(.system(size: 12, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .font(.system(size: 12))
        .frame(height: ShortcutOverlayLayout.rowHeight)
        .opacity(entry.isEnabled ? 1 : 0.4)
    }
}

/// A borderless panel that never becomes key or main and ignores the mouse, so it
/// can't take focus or swallow input.
final class ShortcutOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        setAccessibilityRole(.popover)
        setAccessibilityLabel("Keyboard shortcuts")

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        contentView = effect
    }

    /// Replaces the hosted SwiftUI content and returns its natural size.
    func setContent(_ view: ShortcutOverlayView) -> NSSize {
        guard let effect = contentView else { return .zero }
        effect.subviews.forEach { $0.removeFromSuperview() }
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        setContentSize(size)
        // Track the panel's size, so a clamped frame clips the bottom-right, not the top.
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        return size
    }
}
