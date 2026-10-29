import AppKit

// slimer: tab model for the quick terminal ("drawer"). The drawer window is a
// borderless NSPanel, so AppKit window tabs are not available; instead each tab
// owns a split tree and the controller swaps the visible tree when the selection
// changes. Nothing in here touches AppKit windows so it is unit-testable with a
// mock view type.

/// One tab in the quick terminal drawer.
///
/// A tab owns a split tree and remembers which of its surfaces was focused so that
/// switching back restores focus. This is a class (not a struct) so that undo
/// closures can hold the tab and its surfaces alive until they expire, and so the
/// controller can update per-tab metadata without rebuilding the tab list.
final class QuickTerminalTab<ViewType: NSView & Codable & Identifiable>: Identifiable {
    let id: UUID

    /// The split tree for this tab. For the selected tab this always equals the
    /// controller's `surfaceTree`; for background tabs it is the tree as it was when
    /// the tab was last visible, plus any removals of exited surfaces.
    var surfaceTree: SplitTree<ViewType>

    /// The surface that was focused the last time this tab was visible.
    weak var focusedSurface: ViewType?

    /// A user-set title (via `set_tab_title` / `prompt_tab_title`). When nil the
    /// title is derived from the focused surface.
    var titleOverride: String?

    /// The last title reported by the focused surface. The tab bar shows
    /// `titleOverride ?? title`.
    var title: String = "👻"

    /// True when any surface in this tab currently has an active bell.
    var bell: Bool = false

    init(id: UUID = UUID(), surfaceTree: SplitTree<ViewType>, focusedSurface: ViewType? = nil) {
        self.id = id
        self.surfaceTree = surfaceTree
        self.focusedSurface = focusedSurface ?? surfaceTree.first
    }

    convenience init(view: ViewType) {
        self.init(surfaceTree: SplitTree(view: view), focusedSurface: view)
    }

    /// The title to display for this tab.
    var displayTitle: String {
        if let titleOverride, !titleOverride.isEmpty { return titleOverride }
        return title.isEmpty ? "👻" : title
    }

    func contains(_ view: ViewType) -> Bool {
        surfaceTree.contains(view)
    }

    /// True if this tab and `tree` have at least one surface in common.
    func sharesSurfaces(with tree: SplitTree<ViewType>) -> Bool {
        tree.contains { surfaceTree.contains($0) }
    }
}

/// The ordered list of drawer tabs plus the selection.
///
/// This is a value type that holds all of the index math (insert, remove, move,
/// goto) so that the controller only has to deal with AppKit side effects.
struct QuickTerminalTabs<ViewType: NSView & Codable & Identifiable> {
    typealias Tab = QuickTerminalTab<ViewType>

    /// A `goto_tab` request, decoupled from the libghostty enum so the model can
    /// be tested without GhosttyKit.
    enum Goto: Equatable {
        case previous
        case next
        case last
        /// 1-indexed, as configured by the user (`goto_tab:3`).
        case absolute(Int)
    }

    private(set) var tabs: [Tab] = []

    /// Index of the selected tab. Only meaningful when `tabs` is non-empty; it is
    /// always kept within bounds otherwise.
    private(set) var selectedIndex: Int = 0

    init() {}

    init(tabs: [Tab], selectedIndex: Int = 0) {
        self.tabs = tabs
        self.selectedIndex = tabs.isEmpty ? 0 : min(max(selectedIndex, 0), tabs.count - 1)
    }

    var count: Int { tabs.count }
    var isEmpty: Bool { tabs.isEmpty }

    var selected: Tab? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }

    subscript(index: Int) -> Tab? {
        guard tabs.indices.contains(index) else { return nil }
        return tabs[index]
    }

    func index(of id: Tab.ID) -> Int? {
        tabs.firstIndex { $0.id == id }
    }

    func index(containing view: ViewType) -> Int? {
        tabs.firstIndex { $0.contains(view) }
    }

    func tab(containing view: ViewType) -> Tab? {
        guard let index = index(containing: view) else { return nil }
        return tabs[index]
    }

    func contains(_ view: ViewType) -> Bool {
        index(containing: view) != nil
    }

    /// True if a tab other than the selected one holds the view. The controller
    /// combines this with the visible tree so that ownership is correct even in
    /// the middle of `surfaceTree.didSet`, before the selected tab is synced.
    func containsInBackground(_ view: ViewType) -> Bool {
        let selected = self.selected
        return tabs.contains { $0 !== selected && $0.contains(view) }
    }

    // MARK: Mutation

    /// Insert a tab. By default the tab goes directly after the selected tab, which
    /// is what users expect from Cmd+T. Returns the index the tab ended up at.
    @discardableResult
    mutating func insert(_ tab: Tab, at index: Int? = nil, select: Bool = true) -> Int {
        let target: Int
        if let index {
            target = min(max(index, 0), tabs.count)
        } else if tabs.isEmpty {
            target = 0
        } else {
            target = selectedIndex + 1
        }

        tabs.insert(tab, at: target)
        if select {
            selectedIndex = target
        } else if target <= selectedIndex && tabs.count > 1 {
            // We inserted before the selection; keep the same tab selected.
            selectedIndex += 1
        }
        return target
    }

    /// Select the tab at the index. Returns false if the index is out of range.
    @discardableResult
    mutating func select(index: Int) -> Bool {
        guard tabs.indices.contains(index) else { return false }
        selectedIndex = index
        return true
    }

    @discardableResult
    mutating func select(id: Tab.ID) -> Bool {
        guard let index = index(of: id) else { return false }
        return select(index: index)
    }

    /// Remove the tab at the index and return it. If the removed tab was selected,
    /// the selection moves to the tab that took its place (the former right
    /// neighbor), or to the new last tab when the removed tab was last.
    @discardableResult
    mutating func remove(at index: Int) -> Tab? {
        guard tabs.indices.contains(index) else { return nil }
        let removed = tabs.remove(at: index)
        if tabs.isEmpty {
            selectedIndex = 0
        } else if index < selectedIndex {
            selectedIndex -= 1
        } else if selectedIndex >= tabs.count {
            selectedIndex = tabs.count - 1
        }
        return removed
    }

    @discardableResult
    mutating func remove(id: Tab.ID) -> Tab? {
        guard let index = index(of: id) else { return nil }
        return remove(at: index)
    }

    /// Move a tab from one index to another, keeping the same tab selected.
    mutating func move(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), tabs.indices.contains(destination),
              source != destination else { return }
        let selectedID = selected?.id
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        if let selectedID, let index = index(of: selectedID) {
            selectedIndex = index
        }
    }

    // MARK: Index math

    /// The index a tab at `index` lands on when moved by `amount` (negative is
    /// left), clamped to the ends. Mirrors `move_tab:N`.
    func movedIndex(from index: Int, by amount: Int) -> Int {
        guard !tabs.isEmpty else { return 0 }
        return min(max(index + amount, 0), tabs.count - 1)
    }

    /// The index that a `goto_tab` request resolves to, or nil if there are no tabs
    /// or the request is a no-op. Previous/next wrap around, matching the normal
    /// window behavior. Absolute indexes beyond the end clamp to the last tab.
    func index(for goto: Goto) -> Int? {
        guard !tabs.isEmpty else { return nil }
        switch goto {
        case .previous:
            return selectedIndex == 0 ? tabs.count - 1 : selectedIndex - 1
        case .next:
            return selectedIndex == tabs.count - 1 ? 0 : selectedIndex + 1
        case .last:
            return tabs.count - 1
        case .absolute(let n):
            guard n >= 1 else { return nil }
            return min(n - 1, tabs.count - 1)
        }
    }

    /// The tab to show after removing the tab at `index`, assuming it is selected:
    /// the right neighbor if there is one, otherwise the left neighbor.
    func neighborIndex(forRemoving index: Int) -> Int? {
        guard tabs.count > 1, tabs.indices.contains(index) else { return nil }
        return index == tabs.count - 1 ? index - 1 : index + 1
    }
}
