import AppKit
import GhosttyKit

/// Shows the shortcut sheet when `slimer-shortcut-overlay` is held alone for
/// `slimer-shortcut-overlay-delay`. See docs/slimer/SHORTCUTS.md.
///
/// Input is observed through one in-app local event monitor that always returns the
/// event unchanged: nothing is consumed or delayed. The per-event work is a flag
/// compare and, at most, starting or cancelling one timer. Content is built when the
/// sheet is shown and cached until the config or the main menu changes.
@MainActor
final class ShortcutOverlayController {
    static let shared = ShortcutOverlayController()

    static let fadeDuration: TimeInterval = 0.12

    private var config: Ghostty.Config?
    private var detector = ShortcutOverlayHoldDetector(trigger: nil)
    private var delay: TimeInterval = 2
    private var holdHint = ""
    private var monitor: Any?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    private var panel: ShortcutOverlayPanel?
    private weak var parentWindow: NSWindow?
    /// Bumped on every show and hide so a stale fade-out completion does nothing.
    private var generation = 0

    // Cached content.
    private var menuGroups: [ShortcutGroup]?
    private var menuChords: Set<ShortcutChord> = []
    private var keybindGroups: [ShortcutGroup]?
    private var menuDirty = true

    private init() {}

    /// Called once at launch with the app config. Later configs arrive through
    /// `ghosttyConfigDidChange`.
    func install(config: Ghostty.Config) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: .main) { [weak self] notification in
            guard notification.object == nil,
                  let config = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config
            else { return }
            MainActor.assumeIsolated { self?.apply(config) }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
        // Any menu edit (items added, removed, retitled, re-keyed, enabled) invalidates
        // the menu part. Posted synchronously, so this only flips a flag.
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.menuDirty = true }
                } else {
                    DispatchQueue.main.async { self?.menuDirty = true }
                }
            })
        }
        apply(config)
    }

    func apply(_ config: Ghostty.Config) {
        self.config = config
        keybindGroups = nil
        delay = max(0, config.slimerShortcutOverlayDelay)
        let setting = config.slimerShortcutOverlay
        perform(detector.setTrigger(setting.modifier))
        if let modifier = setting.modifier {
            holdHint = "Release \(ShortcutGlyphs.modifierGlyphs(modifier)) to close"
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    // MARK: Events

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The hot path. Never changes or consumes the event.
    private func observe(_ event: NSEvent) {
        if event.type == .flagsChanged {
            perform(detector.flagsChanged(event.modifierFlags))
        } else if detector.isTracking {
            perform(detector.otherInput())
        }
    }

    private func cancel() {
        perform(detector.deactivated())
    }

    private func perform(_ effect: ShortcutOverlayHoldDetector.Effect) {
        switch effect {
        case .none:
            break
        case .startTimer:
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.timer = nil
                    self.perform(self.detector.timerFired())
                }
            }
        case .cancelTimer:
            timer?.invalidate()
            timer = nil
        case .show:
            show()
        case .hide:
            timer?.invalidate()
            timer = nil
            hide()
        }
    }

    // MARK: Window

    /// The key terminal window (normal or quick terminal), if any.
    private var targetWindow: NSWindow? {
        guard let window = NSApp.keyWindow,
              window.isVisible, !window.isMiniaturized,
              window.windowController is BaseTerminalController else { return nil }
        return window
    }

    private func show() {
        guard let window = targetWindow else { return }
        generation += 1

        let maxSize = NSSize(width: window.frame.width * 0.8, height: window.frame.height * 0.8)
        let capacity = ShortcutOverlayLayout.capacity(for: maxSize)
        let layout = ShortcutOverlayLayout.pack(groups(), maxRows: capacity.rows, maxColumns: capacity.columns)

        let panel = self.panel ?? ShortcutOverlayPanel()
        self.panel = panel
        let natural = panel.setContent(ShortcutOverlayView(layout: layout, holdHint: holdHint))
        let size = NSSize(width: min(natural.width, max(maxSize.width, 320)),
                          height: min(natural.height, max(maxSize.height, 200)))
        let frame = NSRect(
            x: (window.frame.midX - size.width / 2).rounded(),
            y: (window.frame.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height)
        panel.alphaValue = 0
        panel.setFrame(frame, display: false)
        panel.level = window.level

        if parentWindow !== window {
            parentWindow?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parentWindow = window
        }
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.parentWindow?.removeChildWindow(panel)
                self.parentWindow = nil
                panel.orderOut(nil)
            }
        })
    }

    // MARK: Content

    private func groups() -> [ShortcutGroup] {
        // Validate menu items so "disabled here" is current; this marks the cache dirty
        // only if something actually changed.
        if let mainMenu = NSApp.mainMenu { Self.updateItems(mainMenu, skipping: skippedMenus) }

        if menuDirty || menuGroups == nil, let mainMenu = NSApp.mainMenu {
            var chords = Set<ShortcutChord>()
            menuGroups = ShortcutCatalog.menuGroups(
                from: mainMenu, appName: Self.appName, skipping: skippedMenus, chords: &chords)
            // Keybinds already on a menu are left out, so they depend on the chords.
            if chords != menuChords { keybindGroups = nil }
            menuChords = chords
            menuDirty = false
        }

        if keybindGroups == nil {
            keybindGroups = buildKeybindGroups()
        }

        return (menuGroups ?? []) + (keybindGroups ?? []) + [ShortcutCatalog.terminalGroup]
    }

    private func buildKeybindGroups() -> [ShortcutGroup] {
        guard let config else { return [] }
        var titles: [String: String] = [:]
        for command in config.commandPaletteEntries where titles[command.action] == nil {
            titles[command.action] = command.title
        }
        let binds = config.slimerKeybinds.compactMap(ShortcutCatalog.keybind(from:))
        return ShortcutCatalog.keybindGroups(
            binds,
            menuChords: menuChords,
            titles: titles,
            unsupportedActionKeys: Set(Ghostty.Command.unsupportedActionKeys))
    }

    /// The Services menu is built by the system on demand; leave it alone.
    private var skippedMenus: Set<ObjectIdentifier> {
        guard let services = NSApp.servicesMenu else { return [] }
        return [ObjectIdentifier(services)]
    }

    private static func updateItems(_ menu: NSMenu, skipping skipped: Set<ObjectIdentifier>) {
        guard !skipped.contains(ObjectIdentifier(menu)) else { return }
        // Menus with a delegate (Theme, Claude) rebuild themselves when opened, which
        // can be costly; validate only the static ones.
        if menu.delegate == nil { menu.update() }
        for item in menu.items {
            if let submenu = item.submenu { updateItems(submenu, skipping: skipped) }
        }
    }

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ProcessInfo.processInfo.processName
    }
}
