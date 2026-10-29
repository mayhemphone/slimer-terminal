import AppKit
import SwiftUI
import GhosttyKit

/// Slimer autocomplete: one controller per surface. It listens for
/// `ghosttyAutocompleteDidUpdate` (posted when the shell reports a new
/// command line and again when the core's background worker has a result),
/// reads the result with `ghostty_surface_autocomplete_query` (which never
/// blocks: it queues work and reports `pending` until the result arrives),
/// shows or hides the popup, and handles the popup keys while it is visible.
///
/// Keys work like Warp: nothing is selected until the user navigates (arrows,
/// Ctrl-N/P, Shift-Tab). Tab or Right at the end of the line inserts the top
/// suggestion; Enter inserts only a row the user navigated to, otherwise it
/// runs the command as typed (`autocomplete-enter = navigated`). When the
/// popup is hidden every key flows to the terminal exactly as before, except
/// Tab right after a space when suggestions are waiting. Accepting never
/// sends Enter: the core writes `CSI 7705 ~` (or `CSI 7706 ~` for a history
/// line) and the shell's widget edits the line.
@MainActor
final class AutocompleteController {
    private weak var surfaceView: Ghostty.SurfaceView?
    private var popup: AutocompletePopupView?
    /// The suggestions for `buffer`, shown or held back.
    private var suggestions: AutocompleteSuggestions?
    private var buffer: AutocompleteBuffer?
    /// Selected by navigation in the current generation only.
    private var selected: Int?
    /// The shell's keymap is vi (insert or command).
    private var viKeymap = false
    /// After Esc, stay hidden until the buffer changes.
    private var suppressedBuffer: AutocompleteBuffer?
    /// Tab on an empty token opened the popup for this buffer.
    private var openedBuffer: AutocompleteBuffer?
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
              view.focused, view.window?.isKeyWindow == true,
              !view.hasMarkedText() else {
            reset()
            return
        }

        var cBuffer = ghostty_autocomplete_buffer_s()
        guard ghostty_surface_autocomplete_buffer(surface, &cBuffer), cBuffer.len > 0,
              let bytes = cBuffer.buffer else {
            reset()
            return
        }
        let text = bytes.withMemoryRebound(to: UInt8.self, capacity: Int(cBuffer.len)) {
            String(bytes: UnsafeBufferPointer(start: $0, count: Int(cBuffer.len)), encoding: .utf8) ?? ""
        }
        let current = AutocompleteBuffer(text: text, cursor: Int(cBuffer.cursor))
        viKeymap = cBuffer.keymap == UInt8(GHOSTTY_AUTOCOMPLETE_KEYMAP_VIINS.rawValue)
            || cBuffer.keymap == UInt8(GHOSTTY_AUTOCOMPLETE_KEYMAP_VICMD.rawValue)
        if let suppressed = suppressedBuffer {
            if suppressed == current {
                hide()
                return
            }
            suppressedBuffer = nil
        }

        var result = ghostty_autocomplete_result_s()
        let ready = ghostty_surface_autocomplete_query(surface, &result)
        if !ready && result.pending {
            // The worker is on it; the next update brings the result. Keep
            // what is on screen, but a new line invalidates the selection.
            if suggestions?.generation != result.generation { selected = nil }
            return
        }
        guard ready else {
            reset()
            return
        }

        let next = AutocompleteSuggestions(result, maxItems: config?.autocompleteMaxItems ?? 8)
        if next.generation != suggestions?.generation { selected = nil }
        buffer = current
        suggestions = next
        if openedBuffer != nil && openedBuffer != current { openedBuffer = nil }

        guard AutocompleteVisibility.shouldShow(
            buffer: current,
            suggestions: next,
            requested: openedBuffer == current
        ) else {
            // Keep the suggestions so Tab on an empty token can open them.
            popup?.isHidden = true
            selected = nil
            return
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
        let width = min(size.width, bounds.width)
        var originX = max(0, x - tokenWidth)
        originX = min(originX, max(0, bounds.width - width))
        // The ime point's y is the bottom of the cursor cell measured from
        // the top; this view's origin is bottom-left.
        let cursorBottom = bounds.height - y
        let originY: CGFloat
        if cursorBottom / cellHeight >= 9 {
            originY = max(0, cursorBottom - size.height)
        } else {
            originY = max(0, min(bounds.height - size.height, cursorBottom + cellHeight))
        }
        popup.frame = NSRect(x: originX, y: originY, width: width, height: size.height)
        popup.isHidden = false
    }

    /// Hide the popup. Suggestions are kept until the next refresh.
    func hide() {
        popup?.isHidden = true
        selected = nil
    }

    /// Hide and forget everything for this line.
    private func reset() {
        hide()
        suggestions = nil
        buffer = nil
        openedBuffer = nil
    }

    // MARK: - Surface events

    func surfaceFocusChanged(_ focused: Bool) {
        if !focused { hide() }
    }

    // MARK: - Keys

    /// Handle a key. Returns true if consumed. While the popup is hidden
    /// this returns false (the key flows to the terminal as usual) except
    /// for Tab on an empty token with suggestions waiting.
    func handleKey(_ event: NSEvent) -> Bool {
        // Composing with an input method: the IME owns every key.
        if surfaceView?.hasMarkedText() == true {
            hide()
            return false
        }
        guard let suggestions, let buffer else { return false }
        let action = AutocompleteKeys.action(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags,
            context: .init(
                visible: isVisible,
                navigated: selected != nil,
                hasTop: AutocompleteSelection.top(suggestions.items) != nil,
                cursorAtEnd: buffer.cursorAtEnd,
                viKeymap: viKeymap,
                canOpen: AutocompleteVisibility.canOpenWithTab(buffer: buffer, suggestions: suggestions),
                enterMode: config?.autocompleteEnter ?? .navigated
            )
        )
        // The line changed and its result isn't here yet: the shown rows
        // are stale and the core would refuse them. Let the key through.
        if isStale(suggestions) {
            switch action {
            case .acceptSelected, .acceptTop, .open:
                hide()
                return false
            default: break
            }
        }
        switch action {
        case .next:
            selected = AutocompleteSelection.next(selected, count: suggestions.items.count)
            popup?.select(selected)
            return true
        case .previous:
            selected = AutocompleteSelection.previous(selected, count: suggestions.items.count)
            popup?.select(selected)
            return true
        case .acceptSelected:
            guard let index = selected, let item = suggestions.items[safe: index] else { return false }
            accept(item, generation: suggestions.generation)
            return true
        case .acceptTop:
            guard let index = AutocompleteSelection.top(suggestions.items) else { return false }
            accept(suggestions.items[index], generation: suggestions.generation)
            return true
        case .dismiss:
            dismiss(buffer)
            return true
        case .hideAndPassthrough:
            if event.keyCode == AutocompleteKeys.escape { dismiss(buffer) } else { hide() }
            return false
        case .open:
            openedBuffer = buffer
            if let view = surfaceView { show(in: view) }
            return true
        case .passthrough:
            return false
        }
    }

    private func isStale(_ suggestions: AutocompleteSuggestions) -> Bool {
        guard let surface = surfaceView?.surface else { return true }
        var cBuffer = ghostty_autocomplete_buffer_s()
        let live = ghostty_surface_autocomplete_buffer(surface, &cBuffer)
        return !live || cBuffer.generation != suggestions.generation
    }

    private func dismiss(_ buffer: AutocompleteBuffer) {
        suppressedBuffer = buffer
        if let surface = surfaceView?.surface { ghostty_surface_autocomplete_dismiss(surface) }
        hide()
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
