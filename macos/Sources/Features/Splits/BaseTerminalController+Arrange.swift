import AppKit

// slimer: Window > Arrange Panes. Applies the pure transforms in
// SplitTree+Arrange.swift to the controller's current tree (the selected tab's
// tree in the quick terminal) through `replaceSurfaceTree`, so every arrange is
// one undo step. See docs/slimer/PANES.md.
extension BaseTerminalController {
    enum PaneArrangement: CaseIterable {
        case equalizeAll
        case equalWidths
        case equalHeights
        case evenGrid
        case columns
        case rows

        var title: String {
            switch self {
            case .equalizeAll: "Equalize All"
            case .equalWidths: "Equal Widths"
            case .equalHeights: "Equal Heights"
            case .evenGrid: "Even Grid"
            case .columns: "Columns"
            case .rows: "Rows"
            }
        }

        var detail: String {
            switch self {
            case .equalizeAll: "Even out every split in this tab"
            case .equalWidths: "Even out side-by-side splits only"
            case .equalHeights: "Even out stacked splits only"
            case .evenGrid: "Rearrange this tab's panes into an even grid"
            case .columns: "Put every pane side by side"
            case .rows: "Stack every pane"
            }
        }

        var symbol: String {
            switch self {
            case .equalizeAll: "inset.filled.topleft.topright.bottomleft.bottomright.rectangle"
            case .equalWidths: "rectangle.split.3x1"
            case .equalHeights: "rectangle.split.1x2"
            case .evenGrid: "square.grid.2x2"
            case .columns: "rectangle.split.3x1"
            case .rows: "rectangle.split.1x2"
            }
        }
    }

    /// True when the current tab has at least two panes.
    var canArrangePanes: Bool { surfaceTree.isSplit }

    /// Rearrange the current tab. A no-op (and no undo entry) when the tree
    /// would not change. Focus stays on the focused pane.
    func arrangePanes(_ arrangement: PaneArrangement) {
        guard canArrangePanes else { return }

        let newTree: SplitTree<Ghostty.SurfaceView>
        switch arrangement {
        case .equalizeAll: newTree = surfaceTree.equalized()
        case .equalWidths: newTree = surfaceTree.equalized(axis: .horizontal)
        case .equalHeights: newTree = surfaceTree.equalized(axis: .vertical)
        case .evenGrid: newTree = surfaceTree.arrangedEvenGrid(aspectRatio: arrangeAspectRatio)
        case .columns: newTree = surfaceTree.arrangedColumns()
        case .rows: newTree = surfaceTree.arrangedRows()
        }

        guard newTree.root != surfaceTree.root || newTree.zoomed != surfaceTree.zoomed else { return }

        applyArrangedTree(newTree, undoAction: arrangement == .equalizeAll ? "Equalize Splits" : "Arrange Panes")
    }

    /// The pane to refocus after swapping `old` for `new`, or nil to leave
    /// focus alone. Only a structural change (SwiftUI re-parents the views, so
    /// the focused view loses first responder) needs a refocus. A ratio-only
    /// change must not touch focus: resigning and re-making the same first
    /// responder leaves the surface unfocused (hollow cursor, focus-out sent to
    /// the program, secure input dropped).
    static func arrangeRefocusTarget<V: NSView & Codable & Identifiable>(
        from old: SplitTree<V>,
        to new: SplitTree<V>,
        focused: V?
    ) -> V? {
        guard let focused, new.contains(where: { $0 === focused }) else { return nil }
        return old.structuralIdentity == new.structuralIdentity ? nil : focused
    }

    /// Swap in `newTree` with its own undo/redo, like `replaceSurfaceTree`, but
    /// refocusing only per `arrangeRefocusTarget` and never resigning first
    /// (`moveFocus(to:from: nil)`), so the same surface is never on both sides.
    private func applyArrangedTree(_ newTree: SplitTree<Ghostty.SurfaceView>, undoAction: String) {
        let oldTree = surfaceTree
        let focused = focusedSurface
        surfaceTree = newTree
        if let target = Self.arrangeRefocusTarget(from: oldTree, to: newTree, focused: focused) {
            DispatchQueue.main.async { Ghostty.moveFocus(to: target) }
        }

        guard let undoManager else { return }
        undoManager.setActionName(undoAction)
        undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            let current = target.focusedSurface
            let redoTree = target.surfaceTree
            target.surfaceTree = oldTree
            if let view = Self.arrangeRefocusTarget(from: redoTree, to: oldTree, focused: current) {
                DispatchQueue.main.async { Ghostty.moveFocus(to: view) }
            }
            undoManager.registerUndo(withTarget: target, expiresAfter: target.undoExpiration) { target in
                target.applyArrangedTree(newTree, undoAction: undoAction)
            }
        }
    }

    /// Width / height of the area the split tree is drawn in.
    private var arrangeAspectRatio: Double {
        let size = window?.contentView?.bounds.size ?? .zero
        guard size.width > 0, size.height > 0 else { return 1.6 }
        return Double(size.width / size.height)
    }

    @IBAction func arrangePanesEqualWidths(_ sender: Any?) {
        arrangePanes(.equalWidths)
    }

    @IBAction func arrangePanesEqualHeights(_ sender: Any?) {
        arrangePanes(.equalHeights)
    }

    @IBAction func arrangePanesEvenGrid(_ sender: Any?) {
        arrangePanes(.evenGrid)
    }

    @IBAction func arrangePanesColumns(_ sender: Any?) {
        arrangePanes(.columns)
    }

    @IBAction func arrangePanesRows(_ sender: Any?) {
        arrangePanes(.rows)
    }

    /// Menu validation for Arrange Panes items (and upstream Equalize Splits).
    /// Returns nil for items this extension does not own.
    func validateArrangePanesMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(equalizeSplits(_:)),
             #selector(arrangePanesEqualWidths(_:)),
             #selector(arrangePanesEqualHeights(_:)),
             #selector(arrangePanesEvenGrid(_:)),
             #selector(arrangePanesColumns(_:)),
             #selector(arrangePanesRows(_:)):
            return canArrangePanes
        default:
            return nil
        }
    }
}
