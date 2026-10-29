import Foundation

/// The Theme Browser's state machine, separate from its view so it can be tested:
/// filter, move the selection, decide what to preview, then commit or revert exactly once.
///
/// - Moving the selection (arrows, a click, or a filter that hides the current row) asks
///   for a preview of the new row. Previews are throttled: the first one goes out at once,
///   then at most one every ``previewInterval``, always for the latest row, so holding an
///   arrow key never queues up stale work.
/// - ``commit()`` (Enter or double-click) and ``cancel()`` (Esc or closing the panel) end
///   the session; afterwards every call is ignored. Cancel always asks for a revert, so the
///   terminal goes back to what it had before.
///
/// Main thread only.
final class ThemeBrowserModel {
    struct Entry: Hashable, Identifiable {
        enum Kind: Hashable {
            /// "None (use config)".
            case none
            /// "Automatic (follow rules)".
            case automatic
            /// A themes.json theme.
            case theme(UUID)
            /// A Ghostty theme file, by name.
            case ghostty(String)
        }

        let kind: Kind
        let title: String
        /// `#RRGGBB` for the row's swatch, if any.
        var swatchHex: String?

        var id: Kind { kind }
    }

    enum Outcome: Equatable {
        case committed(Entry.Kind)
        case reverted
    }

    /// Runs `work` after `delay` seconds; returns a function that cancels it.
    typealias Scheduler = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void

    static let previewInterval: TimeInterval = 0.05

    static let mainQueueScheduler: Scheduler = { delay, work in
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    private(set) var entries: [Entry]
    private(set) var query = ""
    private(set) var visible: [Entry]
    private(set) var selection: Entry.Kind?
    private(set) var outcome: Outcome?
    /// The last row sent to ``onPreview`` (nil: nothing previewed yet).
    private(set) var lastPreviewed: Entry.Kind?

    var onPreview: (Entry.Kind) -> Void = { _ in }
    var onCommit: (Entry.Kind) -> Void = { _ in }
    var onRevert: () -> Void = {}
    /// Called after the visible rows or the selection change, for the view.
    var onChange: () -> Void = {}

    private let scheduler: Scheduler
    private let interval: TimeInterval
    private var cancelCooldown: (() -> Void)?

    /// - Parameter initial: the row matching what the terminal has now. Selected, but not
    ///   previewed (it is already showing).
    init(
        entries: [Entry],
        initial: Entry.Kind?,
        interval: TimeInterval = ThemeBrowserModel.previewInterval,
        scheduler: @escaping Scheduler = ThemeBrowserModel.mainQueueScheduler
    ) {
        self.entries = entries
        self.visible = entries
        self.initial = initial
        self.interval = interval
        self.scheduler = scheduler
        self.selection = initial.flatMap { kind in entries.contains { $0.kind == kind } ? kind : nil }
    }

    /// The row matching what the terminal had when the browser opened. Kept so it can be
    /// selected once it appears (Ghostty theme names load after the browser opens).
    let initial: Entry.Kind?

    var isFinished: Bool { outcome != nil }

    /// Index of the selection in ``visible``.
    var selectedIndex: Int? {
        guard let selection else { return nil }
        return visible.firstIndex { $0.kind == selection }
    }

    // MARK: Rows

    /// Replaces the rows (e.g. when the Ghostty theme list finishes loading), keeping the
    /// query and, if it still exists, the selection. With nothing selected yet, the
    /// ``initial`` row is selected if it is now listed, without a preview (the terminal is
    /// already showing it).
    func setEntries(_ newEntries: [Entry]) {
        guard !isFinished else { return }
        entries = newEntries
        if let selection, !entries.contains(where: { $0.kind == selection }) {
            self.selection = nil
        }
        if selection == nil, lastPreviewed == nil, let initial, entries.contains(where: { $0.kind == initial }) {
            selection = initial
        }
        refilter(selectFirstIfHidden: false)
    }

    /// Filters by a case- and diacritic-insensitive substring of the title. If the selected
    /// row is filtered out, the first match is selected (and previewed).
    func setQuery(_ newQuery: String) {
        guard !isFinished else { return }
        query = newQuery
        refilter(selectFirstIfHidden: true)
    }

    private func refilter(selectFirstIfHidden: Bool) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            visible = entries
        } else {
            visible = entries.filter {
                $0.title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        if selectFirstIfHidden, selectedIndex == nil, let first = visible.first {
            selection = first.kind
            requestPreview()
        }
        onChange()
    }

    // MARK: Selection

    /// Moves the selection by `delta` rows within the visible rows, clamped. With nothing
    /// selected, down goes to the first row and up to the last.
    func move(by delta: Int) {
        guard !isFinished, !visible.isEmpty, delta != 0 else { return }
        let target: Int
        if let index = selectedIndex {
            target = min(max(index + delta, 0), visible.count - 1)
            guard target != index else { return }
        } else {
            target = delta > 0 ? 0 : visible.count - 1
        }
        selection = visible[target].kind
        requestPreview()
        onChange()
    }

    /// Selects a row (a click). Ignored for rows that aren't visible.
    func select(_ kind: Entry.Kind) {
        guard !isFinished, kind != selection, visible.contains(where: { $0.kind == kind }) else { return }
        selection = kind
        requestPreview()
        onChange()
    }

    // MARK: Ending

    /// Keeps the selected row. Returns false (and does nothing) if no visible row is selected.
    @discardableResult
    func commit() -> Bool {
        guard !isFinished, let selection, selectedIndex != nil else { return false }
        stopCooldown()
        outcome = .committed(selection)
        onCommit(selection)
        return true
    }

    /// Reverts the terminal to what it had before. Ignored after a commit.
    func cancel() {
        guard !isFinished else { return }
        stopCooldown()
        outcome = .reverted
        onRevert()
    }

    // MARK: Preview throttle

    private func requestPreview() {
        // While cooling down, the timer picks up the latest selection when it fires.
        guard cancelCooldown == nil else { return }
        firePreviewIfNeeded()
    }

    private func firePreviewIfNeeded() {
        guard !isFinished, let selection, selection != lastPreviewed else { return }
        lastPreviewed = selection
        onPreview(selection)
        cancelCooldown = scheduler(interval) { [weak self] in
            guard let self else { return }
            self.cancelCooldown = nil
            self.firePreviewIfNeeded()
        }
    }

    private func stopCooldown() {
        cancelCooldown?()
        cancelCooldown = nil
    }
}
