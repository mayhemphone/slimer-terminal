import AppKit
import GhosttyKit

/// Menu entry points for themes:
///
/// - `View ▸ Terminal Theme ▸ …` in the main menu (acts on the key window's focused
///   surface), installed by ``install(into:app:)``;
/// - the same `Terminal Theme ▸` submenu in the terminal's right-click menu (acts on the
///   surface that was clicked), appended by ``appendSurfaceContextItems(to:surface:)``;
/// - a `Theme ▸` submenu and a `Tab Accent ▸` submenu in the native tab context menu,
///   appended by ``appendTabContextItems(to:window:)``.
///
/// Every theme submenu starts with "Browse Themes…" (``ThemeBrowser``). The menus are
/// rebuilt each time they open, so they always reflect the store.
enum ThemeMenu {
    static let mainMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.slimer.terminalThemeMenuItem")
    static let surfaceContextItemIdentifier = NSUserInterfaceItemIdentifier("com.slimer.surfaceContextThemeItem")
    static let contextThemeItemIdentifier = NSUserInterfaceItemIdentifier("com.slimer.tabContextThemeItem")
    static let contextAccentItemIdentifier = NSUserInterfaceItemIdentifier("com.slimer.tabContextAccentItem")

    /// "Browse Themes…" is ⌃⌘T. No default Ghostty keybind uses ctrl+super+t (checked with
    /// `ghostty +list-keybinds --default`), and macOS doesn't reserve it. A user keybind on
    /// that trigger still wins: the surface handles bound keys before the menu sees them.
    static let browseKeyEquivalent = "t"
    static let browseKeyModifiers: NSEvent.ModifierFlags = [.command, .control]

    /// Actions that live in upstream's View menu. The menu is found by these rather than by
    /// its (localizable) title.
    static let viewMenuActions: Set<String> = [
        "increaseFontSize:", "decreaseFontSize:", "resetFontSize:",
        "toggleCommandPalette:", "toggleTerminalInspector:",
    ]

    /// Installs the main-menu item and starts the ``ThemeController``.
    static func install(into mainMenu: NSMenu?, app: Ghostty.App) {
        ThemeController.shared.start(app: app)
        guard let mainMenu else {
            ThemeStore.logger.error("theme menu: no main menu; View ▸ Terminal Theme not installed")
            return
        }
        if !installMenuItem(into: mainMenu) {
            ThemeStore.logger.error("theme menu: View menu not found; View ▸ Terminal Theme not installed")
        }
    }

    /// The main menu's View menu: the top-level submenu holding upstream's font size or
    /// inspector items, else the one titled "View".
    static func viewMenu(in mainMenu: NSMenu) -> NSMenu? {
        let submenus = mainMenu.items.compactMap(\.submenu)
        if let byAction = submenus.first(where: { menu in
            menu.items.contains { item in
                item.action.map { viewMenuActions.contains(NSStringFromSelector($0)) } ?? false
            }
        }) {
            return byAction
        }
        return mainMenu.item(withTitle: "View")?.submenu
    }

    /// Adds `Terminal Theme ▸` to the View menu. Idempotent. Returns false if there is no
    /// View menu.
    @discardableResult
    static func installMenuItem(into mainMenu: NSMenu) -> Bool {
        guard let viewMenu = viewMenu(in: mainMenu) else { return false }
        guard viewMenu.items.first(where: { $0.identifier == mainMenuItemIdentifier }) == nil else { return true }

        let item = NSMenuItem(title: "Terminal Theme", action: nil, keyEquivalent: "")
        item.identifier = mainMenuItemIdentifier
        item.setImageIfDesired(systemSymbolName: "paintpalette")
        let submenu = NSMenu(title: "Terminal Theme")
        submenu.delegate = ThemeMenuBuilder.shared
        submenu.autoenablesItems = false
        item.submenu = submenu

        viewMenu.addItem(.separator())
        viewMenu.addItem(item)
        return true
    }

    /// Appends `Terminal Theme ▸` for `surface` to its right-click menu.
    static func appendSurfaceContextItems(to menu: NSMenu, surface: Ghostty.SurfaceView) {
        let item = NSMenuItem(title: "Terminal Theme", action: nil, keyEquivalent: "")
        item.identifier = surfaceContextItemIdentifier
        item.setImageIfDesired(systemSymbolName: "paintpalette")
        let submenu = NSMenu(title: "Terminal Theme")
        submenu.autoenablesItems = false
        ThemeMenuBuilder.shared.populateThemeMenu(submenu, surface: surface)
        item.submenu = submenu
        menu.addItem(.separator())
        menu.addItem(item)
    }

    /// True if `event` is the "Browse Themes…" shortcut.
    static func isBrowseShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return mods == browseKeyModifiers && event.charactersIgnoringModifiers?.lowercased() == browseKeyEquivalent
    }

    /// Appends the theme and accent submenus for the tab owned by `window`. Removes any
    /// previous copies first, so it is safe to call every time the menu opens.
    static func appendTabContextItems(to menu: NSMenu, window: TerminalWindow?) {
        menu.removeItems(withIdentifiers: [contextThemeItemIdentifier, contextAccentItemIdentifier])
        guard let window else { return }

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.identifier = contextThemeItemIdentifier
        themeItem.setImageIfDesired(systemSymbolName: "paintpalette")
        let themeMenu = NSMenu(title: "Theme")
        themeMenu.autoenablesItems = false
        ThemeMenuBuilder.shared.populateThemeMenu(
            themeMenu,
            surface: window.terminalController?.focusedSurface
        )
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        let accentItem = NSMenuItem(title: "Tab Accent", action: nil, keyEquivalent: "")
        accentItem.identifier = contextAccentItemIdentifier
        accentItem.setImageIfDesired(systemSymbolName: "circle.lefthalf.filled")
        let accentMenu = NSMenu(title: "Tab Accent")
        accentMenu.autoenablesItems = false
        ThemeMenuBuilder.shared.populateAccentMenu(accentMenu, window: window)
        accentItem.submenu = accentMenu
        menu.addItem(accentItem)
    }
}

/// Builds the menus and receives their actions. A single shared instance keeps the
/// target alive for AppKit's weak menu-item targets. Main thread only.
final class ThemeMenuBuilder: NSObject, NSMenuDelegate {
    static let shared = ThemeMenuBuilder()

    /// What a menu item does when selected. Stored as `representedObject`.
    private final class Choice: NSObject {
        enum Kind {
            case browse
            case useTheme(UUID?)
            case automatic
            case folderRule(UUID)
            case openThemesFile
            case reloadThemes
            case accentFollowTheme
            case accentCustom
        }

        let kind: Kind
        weak var surface: Ghostty.SurfaceView?
        weak var window: TerminalWindow?

        init(_ kind: Kind, surface: Ghostty.SurfaceView? = nil, window: TerminalWindow? = nil) {
            self.kind = kind
            self.surface = surface
            self.window = window
        }
    }

    private var controller: ThemeController { .shared }

    /// The surface the main menu acts on.
    private var keySurface: Ghostty.SurfaceView? {
        (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface
    }

    // MARK: NSMenuDelegate (main menu)

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateThemeMenu(menu, surface: keySurface, followsKeySurface: true)
    }

    /// Answers the Browse shortcut without rebuilding the menu on every key equivalent
    /// AppKit checks.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        guard ThemeMenu.isBrowseShortcut(event) else { return false }
        target.pointee = self
        action.pointee = #selector(browseKeySurface(_:))
        return true
    }

    @objc private func browseKeySurface(_ sender: Any?) {
        guard let surface = keySurface else {
            NSSound.beep()
            return
        }
        ThemeBrowser.shared.show(for: surface)
    }

    // MARK: Building

    /// - Parameter followsKeySurface: the main menu's copy. Its Browse item keeps no surface
    ///   and acts on whatever surface is focused when it fires, because AppKit can match its
    ///   key equivalent long after the menu was built.
    func populateThemeMenu(_ menu: NSMenu, surface: Ghostty.SurfaceView?, followsKeySurface: Bool = false) {
        menu.removeAllItems()
        let store = controller.store
        let assignment = surface.map { controller.assignment(for: $0.id) } ?? .automatic
        let applied = surface.flatMap { controller.appliedTheme(for: $0) }

        let browse = makeItem("Browse Themes…", Choice(.browse, surface: followsKeySurface ? nil : surface))
        browse.keyEquivalent = ThemeMenu.browseKeyEquivalent
        browse.keyEquivalentModifierMask = ThemeMenu.browseKeyModifiers
        browse.isEnabled = surface != nil
        browse.setImageIfDesired(systemSymbolName: "magnifyingglass")
        menu.addItem(browse)
        menu.addItem(.separator())

        // Explicit "none".
        let none = makeItem("None (use config)", Choice(.useTheme(nil), surface: surface))
        none.state = assignment == .explicit(.none) ? .on : .off
        none.isEnabled = surface != nil
        menu.addItem(none)

        // Automatic.
        let auto = makeItem("Automatic (follow rules)", Choice(.automatic, surface: surface))
        auto.state = assignment == .automatic ? .on : .off
        auto.isEnabled = surface != nil
        menu.addItem(auto)

        menu.addItem(.separator())

        if store.themes.isEmpty {
            let empty = NSMenuItem(title: "No themes in themes.json", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        // A pin to a theme that no longer exists in themes.json.
        if case .explicit(.theme(let id)) = assignment, store.theme(id: id) == nil {
            let missing = NSMenuItem(title: "Missing Theme (removed from themes.json)", action: nil, keyEquivalent: "")
            missing.state = .on
            missing.isEnabled = false
            menu.addItem(missing)
        }

        // A pinned Ghostty theme (chosen in the Theme Browser).
        if case .explicit(.ghostty(let name)) = assignment {
            let pinned = NSMenuItem(title: "Ghostty Theme: \(name)", action: nil, keyEquivalent: "")
            pinned.state = .on
            pinned.isEnabled = false
            menu.addItem(pinned)
        }

        for theme in store.themes {
            let resolves = controller.namedThemeResolves(theme)
            let title = resolves ? theme.name : "\(theme.name) (Ghostty theme not found)"
            let item = makeItem(title, Choice(.useTheme(theme.id), surface: surface))
            // A theme whose only content is an unresolvable Ghostty theme does nothing.
            let usable = resolves || theme.background != nil || theme.foreground != nil ||
                theme.cursorColor != nil || theme.selectionBackground != nil || theme.accent != nil
            item.isEnabled = surface != nil && usable
            if !resolves, let name = theme.ghosttyTheme {
                item.toolTip = "“\(name)” is not a plain theme name in ~/.config/ghostty/themes or the app bundle."
            }
            if case .explicit(.theme(let id)) = assignment, id == theme.id {
                item.state = .on
            } else if assignment == .automatic, applied?.id == theme.id {
                // Chosen by a rule: show it as mixed so it reads as "active but not pinned".
                item.state = .mixed
            }
            item.image = Self.swatch(for: theme)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Folder rule for the currently applied theme.
        let folderTitle: String
        if let applied, let pwd = surface?.pwd, !pwd.isEmpty {
            folderTitle = "Always Use “\(applied.name)” for \(Self.abbreviate(pwd))"
        } else {
            folderTitle = "Always Use for This Folder"
        }
        let folder = makeItem(folderTitle, Choice(applied.map { .folderRule($0.id) } ?? .automatic, surface: surface))
        folder.isEnabled = applied != nil && !(surface?.pwd ?? "").isEmpty
        folder.setImageIfDesired(systemSymbolName: "folder.badge.plus")
        menu.addItem(folder)

        menu.addItem(.separator())

        let open = makeItem("Edit themes.json…", Choice(.openThemesFile))
        open.setImageIfDesired(systemSymbolName: "doc.text")
        menu.addItem(open)
        menu.addItem(makeItem("Reload Themes", Choice(.reloadThemes)))

        if store.persistence != .writable {
            let warning = NSMenuItem(
                title: "themes.json can’t be safely rewritten; changes aren’t saved",
                action: nil,
                keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
    }

    func populateAccentMenu(_ menu: NSMenu, window: TerminalWindow) {
        menu.removeAllItems()

        let follow = makeItem("Follow Theme", Choice(.accentFollowTheme, window: window))
        follow.state = (window.tabAccentHex == nil && window.tabColor == .none) ? .on : .off
        menu.addItem(follow)

        let custom = makeItem("Custom Color…", Choice(.accentCustom, window: window))
        custom.state = window.tabAccentHex != nil ? .on : .off
        if let hex = window.tabAccentHex, let color = NSColor(strictHex: hex) {
            custom.image = Self.swatch(color: color)
        }
        menu.addItem(custom)

        let hint = NSMenuItem(title: "Palette colors above override both.", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
    }

    private func makeItem(_ title: String, _ choice: Choice) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performChoice(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = choice
        return item
    }

    // MARK: Actions

    @objc private func performChoice(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        switch choice.kind {
        case .browse:
            guard let surface = choice.surface ?? keySurface else {
                NSSound.beep()
                return
            }
            ThemeBrowser.shared.show(for: surface)

        case .useTheme(let id):
            guard let surface = choice.surface else { return }
            controller.setExplicitTheme(id, for: surface)

        case .automatic:
            guard let surface = choice.surface else { return }
            controller.clearExplicitTheme(for: surface)

        case .folderRule(let themeId):
            guard let surface = choice.surface else { return }
            controller.addFolderRule(for: surface, themeId: themeId)

        case .openThemesFile:
            NSWorkspace.shared.open(controller.store.fileURL)

        case .reloadThemes:
            controller.store.reload()

        case .accentFollowTheme:
            guard let window = choice.window else { return }
            window.tabAccentHex = nil
            window.tabColor = .none

        case .accentCustom:
            guard let window = choice.window else { return }
            colorPanelWindow = window
            let panel = NSColorPanel.shared
            panel.showsAlpha = false
            if let hex = window.tabAccentHex, let color = NSColor(strictHex: hex) {
                panel.color = color
            } else if let color = window.effectiveTabAccentColor {
                panel.color = color
            }
            panel.setTarget(self)
            panel.setAction(#selector(colorPanelDidChange(_:)))
            colorPanelAttached = true
            observeColorPanelClose(panel)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private weak var colorPanelWindow: TerminalWindow?
    private var colorPanelCloseObserver: NSObjectProtocol?
    private var colorPanelAttached = false

    @objc private func colorPanelDidChange(_ sender: NSColorPanel) {
        guard let window = colorPanelWindow else {
            detachColorPanel(sender)
            return
        }
        guard let hex = sender.color.strictHexString, SurfaceTheme.isValidHex(hex) else { return }
        // A custom accent replaces any upstream palette color, which would otherwise win.
        window.tabColor = .none
        window.tabAccentHex = hex
    }

    /// The shared color panel outlives this use; stop routing its changes here once it
    /// closes so a later, unrelated use of the panel can't recolor this tab.
    private func observeColorPanelClose(_ panel: NSColorPanel) {
        if let observer = colorPanelCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        colorPanelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.detachColorPanel(panel)
        }
    }

    private func detachColorPanel(_ panel: NSColorPanel) {
        if colorPanelAttached {
            panel.setTarget(nil)
            panel.setAction(nil)
            colorPanelAttached = false
        }
        colorPanelWindow = nil
        if let observer = colorPanelCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            colorPanelCloseObserver = nil
        }
    }

    // MARK: Helpers

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func swatch(for theme: SurfaceTheme) -> NSImage? {
        let hex = theme.accent ?? theme.background
        guard let hex, let color = NSColor(strictHex: hex) else { return nil }
        return swatch(color: color)
    }

    private static func swatch(color: NSColor) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            color.setFill()
            path.fill()
            NSColor.quaternaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
