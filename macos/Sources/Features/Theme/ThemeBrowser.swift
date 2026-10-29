import AppKit

/// The per-terminal Theme Browser: a popover anchored to one terminal with a search field
/// and one list (None, Automatic, the themes.json themes, then every Ghostty theme).
///
/// Arrows or a click preview the row on that terminal only (``ThemeController/preview(_:on:)``,
/// nothing written, nothing pinned); typing filters; Enter or a double-click pins the row;
/// Esc or closing the popover reverts. The logic lives in ``ThemeBrowserModel``; this type
/// only wires it to AppKit and the ``ThemeController``.
///
/// Main thread only. One browser at a time: opening another reverts the first.
final class ThemeBrowser: NSObject {
    static let shared = ThemeBrowser()

    private var session: Session?
    /// Ghostty theme names from the last directory scan. Reused for the next open (and
    /// refreshed in the background), so the list appears instantly after the first time.
    private var cachedGhosttyNames: [String]?
    private var scanGeneration = 0

    private var controller: ThemeController { .shared }

    private final class Session {
        weak var surface: Ghostty.SurfaceView?
        let model: ThemeBrowserModel
        let popover: NSPopover
        let viewController: ThemeBrowserViewController

        init(surface: Ghostty.SurfaceView, model: ThemeBrowserModel,
             popover: NSPopover, viewController: ThemeBrowserViewController) {
            self.surface = surface
            self.model = model
            self.popover = popover
            self.viewController = viewController
        }
    }

    // MARK: Showing

    func show(for surface: Ghostty.SurfaceView) {
        // Reverts and closes any open browser first.
        close()
        guard surface.window != nil else { return }

        let store = controller.store
        let names = cachedGhosttyNames ?? []
        let model = ThemeBrowserModel(
            entries: Self.entries(themes: store.themes, ghosttyNames: names),
            initial: Self.initialKind(for: controller.assignment(for: surface.id))
        )
        let viewController = ThemeBrowserViewController(model: model)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = viewController
        popover.delegate = self

        let session = Session(surface: surface, model: model, popover: popover, viewController: viewController)
        self.session = session

        model.onPreview = { [weak self, weak session] kind in
            guard let self, let surface = session?.surface else { return }
            self.controller.preview(self.previewTheme(for: kind, surface: surface), on: surface)
        }
        model.onCommit = { [weak self, weak session] kind in
            guard let self, let surface = session?.surface else { return }
            self.commit(kind, on: surface)
            session?.popover.close()
        }
        model.onRevert = { [weak self, weak session] in
            guard let self, let surface = session?.surface else { return }
            self.controller.endPreview(for: surface)
        }

        // Top center of the terminal, inside it, so the popover covers this pane only.
        let bounds = surface.bounds
        let anchor = NSRect(x: bounds.midX - 1, y: max(bounds.maxY - 12, bounds.minY), width: 2, height: 2)
        popover.show(relativeTo: anchor, of: surface, preferredEdge: .minY)
        viewController.focusSearchField()

        loadGhosttyNames()
    }

    /// Reverts and closes the open browser, if any.
    func close() {
        guard let session else { return }
        self.session = nil
        session.model.cancel()
        session.popover.close()
    }

    // MARK: Rows

    static func entries(themes: [SurfaceTheme], ghosttyNames: [String]) -> [ThemeBrowserModel.Entry] {
        var rows: [ThemeBrowserModel.Entry] = [
            .init(kind: .none, title: "None (use config)"),
            .init(kind: .automatic, title: "Automatic (follow rules)"),
        ]
        rows += themes.map {
            .init(kind: .theme($0.id), title: $0.name.isEmpty ? "Untitled" : $0.name,
                  swatchHex: $0.accent ?? $0.background)
        }
        // Names come from a directory listing; keep only the ones a pin would accept.
        rows += ghosttyNames.compactMap { name in
            ThemePin.validGhosttyName(name).map { .init(kind: .ghostty($0), title: $0) }
        }
        return rows
    }

    static func initialKind(for assignment: ThemeController.Assignment) -> ThemeBrowserModel.Entry.Kind {
        switch assignment {
        case .automatic: return .automatic
        case .explicit(.none): return .none
        case .explicit(.theme(let id)): return .theme(id)
        case .explicit(.ghostty(let name)): return .ghostty(name)
        }
    }

    private func loadGhosttyNames() {
        scanGeneration += 1
        let generation = scanGeneration
        let dirs = GhosttyThemeResolver.searchDirectories()
        DispatchQueue.global(qos: .userInitiated).async {
            let names = GhosttyThemeResolver.themeNames(in: dirs)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.scanGeneration else { return }
                let changed = names != self.cachedGhosttyNames
                self.cachedGhosttyNames = names
                guard changed, let session = self.session, !session.model.isFinished else { return }
                session.model.setEntries(Self.entries(themes: self.controller.store.themes, ghosttyNames: names))
            }
        }
    }

    // MARK: Applying

    private func previewTheme(for kind: ThemeBrowserModel.Entry.Kind, surface: Ghostty.SurfaceView) -> SurfaceTheme? {
        switch kind {
        case .none: return nil
        case .automatic: return controller.ruleTheme(for: surface)
        case .theme(let id): return controller.store.theme(id: id)
        case .ghostty(let name):
            guard let valid = ThemePin.validGhosttyName(name) else { return nil }
            return ThemePin.surfaceTheme(forGhosttyName: valid)
        }
    }

    private func commit(_ kind: ThemeBrowserModel.Entry.Kind, on surface: Ghostty.SurfaceView) {
        switch kind {
        case .none: controller.setPin(.none, for: surface)
        case .automatic: controller.clearExplicitTheme(for: surface)
        case .theme(let id): controller.setPin(.theme(id), for: surface)
        case .ghostty(let name): controller.setPin(.ghostty(name), for: surface)
        }
        controller.endPreview(for: surface)
    }
}

extension ThemeBrowser: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, let session, session.popover === popover else { return }
        self.session = nil
        // Closing without Enter (click outside, Esc, the surface going away) reverts.
        session.model.cancel()
    }
}

// MARK: - View

/// Search field over a table. The search field keeps keyboard focus (the table refuses first
/// responder), so typing always filters and the arrows, Enter and Esc go to the model.
final class ThemeBrowserViewController: NSViewController, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private let model: ThemeBrowserModel
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var syncingSelection = false

    private static let rowIdentifier = NSUserInterfaceItemIdentifier("ThemeBrowserRow")

    init(model: ThemeBrowserModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        model.onChange = { [weak self] in self?.reload() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 420))

        searchField.placeholderString = "Filter themes"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsEmptySelection = true
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "↑↓ preview   ↩ keep   esc revert")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(hint)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            hint.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root
        preferredContentSize = root.frame.size
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Always show the scroller (overlay scrollers hide until you scroll).
        scrollView.scrollerStyle = .legacy
        focusSearchField()
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    private func reload() {
        guard isViewLoaded else { return }
        // reloadData can trim the old selection and notify; that isn't the user's choice.
        syncingSelection = true
        tableView.reloadData()
        syncingSelection = false
        syncSelection()
    }

    private func syncSelection() {
        syncingSelection = true
        defer { syncingSelection = false }
        if let index = model.selectedIndex {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: Search field

    func controlTextDidChange(_ obj: Notification) {
        model.setQuery(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            model.move(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            model.move(by: 1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
            model.move(by: -pageSize)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
            model.move(by: pageSize)
        case #selector(NSResponder.insertNewline(_:)):
            model.commit()
        case #selector(NSResponder.cancelOperation(_:)):
            // Reverts, then closes.
            ThemeBrowser.shared.close()
        default:
            return false
        }
        return true
    }

    private var pageSize: Int {
        max(1, Int(scrollView.contentView.bounds.height / max(tableView.rowHeight, 1)) - 1)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        model.visible.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.visible.indices.contains(row) else { return nil }
        let entry = model.visible[row]
        let cell = (tableView.makeView(withIdentifier: Self.rowIdentifier, owner: self) as? ThemeBrowserCell)
            ?? ThemeBrowserCell(identifier: Self.rowIdentifier)
        cell.configure(entry)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let row = tableView.selectedRow
        guard model.visible.indices.contains(row) else {
            // Clicking empty space would clear the selection; keep the model's.
            syncSelection()
            return
        }
        model.select(model.visible[row].kind)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard model.visible.indices.contains(row) else { return }
        model.select(model.visible[row].kind)
        model.commit()
    }
}

/// One row: an optional color swatch, the name, and a dim source label.
private final class ThemeBrowserCell: NSTableCellView {
    private let swatch = NSView()
    private let label = NSTextField(labelWithString: "")
    private let source = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 5
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor.quaternaryLabelColor.cgColor
        label.lineBreakMode = .byTruncatingTail
        source.textColor = .tertiaryLabelColor
        source.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        source.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [swatch, label, source] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = label
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 10),
            swatch.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            source.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            source.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            source.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(_ entry: ThemeBrowserModel.Entry) {
        label.stringValue = entry.title
        if let hex = entry.swatchHex, let color = NSColor(strictHex: hex) {
            swatch.isHidden = false
            swatch.layer?.backgroundColor = color.cgColor
        } else {
            swatch.isHidden = true
        }
        switch entry.kind {
        case .none, .automatic: source.stringValue = ""
        case .theme: source.stringValue = "Slimer"
        case .ghostty: source.stringValue = "Ghostty"
        }
    }
}
