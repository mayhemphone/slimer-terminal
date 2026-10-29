import AppKit
import GhosttyKit

/// Menu entry points for themes:
///
/// - `Terminal ▸ Terminal Theme ▸ …` in the main menu (acts on the key window's focused
///   surface), installed by ``install(into:app:)``;
/// - a `Theme ▸` submenu and a `Tab Accent ▸` submenu in the native tab context menu,
///   appended by ``appendTabContextItems(to:window:)``.
///
/// Both menus are rebuilt each time they open, so they always reflect the store.
enum ThemeMenu {
    static let mainMenuItemIdentifier = NSUserInterfaceItemIdentifier("com.slimer.terminalThemeMenuItem")
    static let contextThemeItemIdentifier = NSUserInterfaceItemIdentifier("com.slimer.tabContextThemeItem")
    static let contextAccentItemIdentifier = NSUserInterfaceItemIdentifier("com.slimer.tabContextAccentItem")

    /// Installs the main-menu item and starts the ``ThemeController``.
    static func install(into mainMenu: NSMenu?, app: Ghostty.App) {
        ThemeController.shared.start(app: app)

        guard let mainMenu else { return }
        guard let terminalMenu = mainMenu.item(withTitle: "Terminal")?.submenu else { return }
        guard terminalMenu.items.first(where: { $0.identifier == mainMenuItemIdentifier }) == nil else { return }

        let item = NSMenuItem(title: "Terminal Theme", action: nil, keyEquivalent: "")
        item.identifier = mainMenuItemIdentifier
        item.setImageIfDesired(systemSymbolName: "paintpalette")
        let submenu = NSMenu(title: "Terminal Theme")
        submenu.delegate = ThemeMenuBuilder.shared
        submenu.autoenablesItems = false
        item.submenu = submenu

        terminalMenu.addItem(.separator())
        terminalMenu.addItem(item)
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
        populateThemeMenu(menu, surface: keySurface)
    }

    // MARK: Building

    func populateThemeMenu(_ menu: NSMenu, surface: Ghostty.SurfaceView?) {
        menu.removeAllItems()
        let store = controller.store
        let assignment = surface.map { controller.assignment(for: $0.id) } ?? .automatic
        let applied = surface.flatMap { controller.appliedTheme(for: $0) }

        // Explicit "none".
        let none = makeItem("None (use config)", Choice(.useTheme(nil), surface: surface))
        none.state = assignment == .explicit(nil) ? .on : .off
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

        for theme in store.themes {
            let item = makeItem(theme.name, Choice(.useTheme(theme.id), surface: surface))
            item.isEnabled = surface != nil
            if case .explicit(let id) = assignment, id == theme.id {
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
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private weak var colorPanelWindow: TerminalWindow?

    @objc private func colorPanelDidChange(_ sender: NSColorPanel) {
        guard let window = colorPanelWindow else { return }
        guard let hex = sender.color.hexString, SurfaceTheme.isValidHex(hex) else { return }
        window.tabAccentHex = hex
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
