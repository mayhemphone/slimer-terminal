import AppKit
import SwiftUI
import GhosttyKit

/// Slimer autocomplete: one controller per surface. It listens for
/// `ghosttyAutocompleteDidUpdate`, runs the core suggestion engine (on the
/// main thread, coalesced to one query per run loop turn), shows or hides
/// the popup, and handles the six popup keys while it is visible.
///
/// When the popup is hidden every key flows to the terminal exactly as
/// before. Accepting never sends Enter: the core writes `CSI 7705 ~` (or
/// `CSI 7706 ~` for a history line) and the shell's widget edits the line.
@MainActor
final class AutocompleteController {
    private weak var surfaceView: Ghostty.SurfaceView?
    private var popup: AutocompletePopupView?
    private var suggestions: AutocompleteSuggestions?
    private var buffer: AutocompleteBuffer?
    private var selected: Int?
    /// After Esc, stay hidden until the buffer changes.
    private var suppressedBuffer: AutocompleteBuffer?
    private var refreshScheduled = false
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { popup?.isHidden == false }

    private init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        Self.configurePathsOnce()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: Ghostty.Notification.ghosttyAutocompleteDidUpdate,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow,
                      window === self.surfaceView?.window else { return }
                self.hide()
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Per-surface storage

    private static var associationKey: UInt8 = 0

    /// The controller for a surface, created on first use (the first key
    /// press, which always precedes the first buffer report).
    static func controller(for surfaceView: Ghostty.SurfaceView) -> AutocompleteController {
        if let existing = objc_getAssociatedObject(surfaceView, &associationKey) as? AutocompleteController {
            return existing
        }
        let controller = AutocompleteController(surfaceView: surfaceView)
        objc_setAssociatedObject(surfaceView, &associationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    static func existing(for surfaceView: Ghostty.SurfaceView) -> AutocompleteController? {
        objc_getAssociatedObject(surfaceView, &associationKey) as? AutocompleteController
    }

    // MARK: - History location

    private static var pathsConfigured = false

    /// Tell the core where history lives, once, before the first query.
    private static func configurePathsOnce() {
        guard !pathsConfigured else { return }
        pathsConfigured = true
        let dir = dataDirectory().path
        dir.withCString { ptr in
            ghostty_autocomplete_set_paths(ptr, UInt(dir.utf8.count), nil, 0)
        }
    }

    /// `$XDG_DATA_HOME/slimer` when absolute, else `~/.local/share/slimer`.
    /// Under XCTest a throwaway temporary directory, so tests never touch
    /// the real history.
    nonisolated static func dataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if environment["XCTestConfigurationFilePath"] != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("slimer-xctest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("slimer", isDirectory: true)
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".local/share/slimer", isDirectory: true)
    }

    // MARK: - Config

    private var config: Ghostty.Config? {
        (NSApp.delegate as? AppDelegate)?.ghostty.config
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    private func refresh() {
        guard let view = surfaceView, let surface = view.surface,
              config?.autocompleteEnabled ?? true,
              view.focused, view.window?.isKeyWindow == true else {
            hide()
            return
        }

        var cBuffer = ghostty_autocomplete_buffer_s()
        guard ghostty_surface_autocomplete_buffer(surface, &cBuffer), cBuffer.len > 0,
              let bytes = cBuffer.buffer else {
            hide()
            return
        }
        let text = bytes.withMemoryRebound(to: UInt8.self, capacity: Int(cBuffer.len)) {
            String(bytes: UnsafeBufferPointer(start: $0, count: Int(cBuffer.len)), encoding: .utf8) ?? ""
        }
        let current = AutocompleteBuffer(text: text, cursor: Int(cBuffer.cursor))
        if let suppressed = suppressedBuffer {
            if suppressed == current {
                hide()
                return
            }
            suppressedBuffer = nil
        }

        var result = ghostty_autocomplete_result_s()
        guard ghostty_surface_autocomplete_query(surface, &result) else {
            hide()
            return
        }
        let next = AutocompleteSuggestions(result, maxItems: config?.autocompleteMaxItems ?? 8)
        guard AutocompleteVisibility.shouldShow(buffer: current, suggestions: next) else {
            hide()
            return
        }

        // Keep the selection on the same text if it is still offered.
        let previousText = selected.flatMap { index in suggestions?.items[safe: index]?.text }
        buffer = current
        suggestions = next
        if let previousText, let index = next.items.firstIndex(where: { $0.text == previousText }),
           !next.items[index].dangerous {
            selected = index
        } else {
            selected = AutocompleteSelection.initial(next.items)
        }
        show(in: view)
    }

    private func show(in view: Ghostty.SurfaceView) {
        guard let suggestions, let surface = view.surface else { return }
        let popup = self.popup ?? {
            let p = AutocompletePopupView(frame: .zero)
            view.addSubview(p)
            self.popup = p
            return p
        }()

        let background = NSColor(view.backgroundColor ?? view.derivedConfig.backgroundColor)
        let foreground = config?.autocompleteForeground
            ?? (background.usingColorSpace(.sRGB)?.brightnessComponent ?? 0 < 0.5 ? .white : .black)
        let cell = view.cellSize
        let size = popup.update(
            items: suggestions.items,
            selected: selected,
            palette: .init(background: background, foreground: foreground),
            fontSize: cell.height > 0 ? cell.height * 0.72 : 12
        )

        // Anchor at the start of the replaced token, just below the cursor
        // row; flip above when fewer than 9 rows fit below.
        var x: Double = 0
        var y: Double = 0
        var w: Double = 0
        var h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let cellHeight = max(cell.height, 1)
        let tokenWidth = Double(suggestions.replaceColumns) * cell.width
        let bounds = view.bounds
        var originX = max(0, x - tokenWidth)
        originX = min(originX, max(0, bounds.width - size.width))
        // The ime point's y is the bottom of the cursor cell measured from
        // the top; this view's origin is bottom-left.
        let cursorBottom = bounds.height - y
        let originY: CGFloat
        if cursorBottom / cellHeight >= 9 {
            originY = max(0, cursorBottom - size.height)
        } else {
            originY = max(0, min(bounds.height - size.height, cursorBottom + cellHeight))
        }
        popup.frame = NSRect(x: originX, y: originY, width: size.width, height: size.height)
        popup.isHidden = false
    }

    func hide() {
        popup?.isHidden = true
        suggestions = nil
        selected = nil
    }

    // MARK: - Surface events

    func surfaceFocusChanged(_ focused: Bool) {
        if !focused { hide() }
    }

    // MARK: - Keys

    /// Handle a key while the popup is visible. Returns true if consumed.
    /// When the popup is hidden this always returns false so the key flows
    /// to the terminal as usual.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isVisible, let suggestions, let buffer else { return false }
        let action = AutocompleteKeys.action(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            enterMode: config?.autocompleteEnter ?? .accept,
            hasSelection: selected != nil,
            cursorAtEnd: buffer.cursorAtEnd
        )
        switch action {
        case .next:
            selected = AutocompleteSelection.next(selected, count: suggestions.items.count)
            popup?.select(selected)
            return true
        case .previous:
            selected = AutocompleteSelection.previous(selected, count: suggestions.items.count)
            popup?.select(selected)
            return true
        case .dismiss:
            suppressedBuffer = buffer
            if let surface = surfaceView?.surface { ghostty_surface_autocomplete_dismiss(surface) }
            hide()
            return true
        case .accept:
            guard let index = selected, let item = suggestions.items[safe: index] else { return false }
            accept(item, generation: suggestions.generation)
            return true
        case .passthrough:
            // Enter in passthrough mode runs the line: the popup goes away.
            if event.keyCode == AutocompleteKeys.enter || event.keyCode == AutocompleteKeys.keypadEnter {
                hide()
            }
            return false
        }
    }

    private func accept(_ item: AutocompleteItem, generation: UInt64) {
        hide()
        guard let surface = surfaceView?.surface else { return }
        let len = UInt(item.text.utf8.count)
        let ok = item.text.withCString { ptr in
            item.replacesLine
                ? ghostty_surface_autocomplete_accept_line(surface, generation, ptr, len)
                : ghostty_surface_autocomplete_accept(surface, generation, ptr, len)
        }
        if !ok { Ghostty.logger.debug("autocomplete: accept refused by the core") }
    }
}

extension Ghostty.SurfaceView {
    /// slimer: the surface's autocomplete controller (created on first use).
    var autocompleteController: AutocompleteController? {
        AutocompleteController.controller(for: self)
    }

    /// slimer: the controller if one exists, without creating it.
    var existingAutocompleteController: AutocompleteController? {
        AutocompleteController.existing(for: self)
    }
}
