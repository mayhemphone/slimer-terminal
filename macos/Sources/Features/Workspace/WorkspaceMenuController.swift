import AppKit
import Combine

/// Builds and maintains the top-level "Workspace" menu: pinned items at the
/// top, then Locations / Commands / Recent submenus, then file actions. The
/// menu is rebuilt whenever the store changes. Each location gets an
/// ⌥-alternate that opens a new tab instead of `cd`-ing in place.
/// Main thread only.
final class WorkspaceMenuController: NSObject, NSMenuItemValidation {
    private enum MenuAction {
        case location(WorkspaceLocation, WorkspaceActions.OpenMode)
        case recent(String, WorkspaceActions.OpenMode)
        case command(WorkspaceCommand)
        case openFile
        case reload
    }

    /// How many recent directories to list in the Recent submenu.
    static let recentLimit = 15

    private let store: WorkspaceStore
    private let menuItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
    private let menu = NSMenu(title: "Workspace")
    private var cancellables: Set<AnyCancellable> = []
    private var installed = false
    /// Whether the last rebuild could check shortcuts against Ghostty's
    /// keybindings (needs a live surface). If not, we rebuild once a terminal
    /// window becomes key.
    private var checkedBindings = false

    init(store: WorkspaceStore) {
        self.store = store
        super.init()
        menuItem.submenu = menu
    }

    /// Insert the menu into the main menu (before "Window") and start
    /// following the store. Safe to call more than once.
    func install() {
        guard !installed, let mainMenu = NSApp.mainMenu else { return }
        installed = true

        let index = mainMenu.items.firstIndex {
            ($0.submenu != nil && $0.submenu === NSApp.windowsMenu) || $0.title == "Window"
        } ?? mainMenu.items.count
        mainMenu.insertItem(menuItem, at: index)

        // @Published emits on willSet; hop to the next run loop turn so the
        // store's state is current when we rebuild.
        Publishers.Merge4(
            store.$document.map { _ in () },
            store.$loadError.map { _ in () },
            store.$recent.map { _ in () },
            store.$usage.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.rebuild() }
        .store(in: &cancellables)

        // Keybindings can change with the Ghostty config.
        NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        // Shortcut collision checks need a surface; retry when one appears.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in
                guard let self, !self.checkedBindings, self.bindingSurface != nil else { return }
                self.rebuild()
            }
            .store(in: &cancellables)

        rebuild()
    }

    // MARK: - Building

    /// Any live surface, used to ask libghostty about keybindings (they are
    /// app-wide config, so any surface answers the same).
    private var bindingSurface: Ghostty.Surface? {
        TerminalController.preferredParent?.focusedSurface?.surfaceModel
            ?? TerminalController.all.lazy.compactMap { $0.focusedSurface?.surfaceModel }.first
    }

    /// Apply the shortcut policy (must contain ⌘, must not be a Ghostty
    /// keybinding).
    private func acceptedShortcut(_ string: String?) -> WorkspaceShortcut? {
        let surface = bindingSurface
        return WorkspaceShortcut.accepted(string) { shortcut in
            guard let surface else { return false }
            return WorkspaceShortcut.isGhosttyBinding(shortcut, on: surface)
        }
    }

    private func isFree(_ shortcut: WorkspaceShortcut) -> Bool {
        guard let surface = bindingSurface else { return true }
        return !WorkspaceShortcut.isGhosttyBinding(shortcut, on: surface)
    }

    private func rebuild() {
        checkedBindings = bindingSurface != nil
        menu.removeAllItems()
        let now = Date()
        let locations = store.rankedLocations(now: now)
        let commands = store.rankedCommands(now: now)

        // Pinned items at the top level.
        let pinnedLocations = locations.filter(\.pinned)
        let pinnedCommands = commands.filter(\.pinned)
        for location in pinnedLocations {
            addLocationItems(location, to: menu, withShortcut: true)
        }
        for command in pinnedCommands {
            menu.addItem(commandItem(command, withShortcut: true))
        }
        if !pinnedLocations.isEmpty || !pinnedCommands.isEmpty {
            menu.addItem(.separator())
        }

        // Locations
        let locationsMenu = NSMenu(title: "Locations")
        if locations.isEmpty {
            locationsMenu.addItem(disabledItem("No Locations"))
        }
        for location in locations {
            addLocationItems(location, to: locationsMenu, withShortcut: !location.pinned)
        }
        menu.addItem(submenuItem("Locations", locationsMenu))

        // Commands
        let commandsMenu = NSMenu(title: "Commands")
        if commands.isEmpty {
            commandsMenu.addItem(disabledItem("No Commands"))
        }
        for command in commands {
            commandsMenu.addItem(commandItem(command, withShortcut: !command.pinned))
        }
        menu.addItem(submenuItem("Commands", commandsMenu))

        // Recent
        let recentMenu = NSMenu(title: "Recent")
        let locationPaths = Set(locations.map(\.expandedPath))
        let recents = store.rankedRecent(now: now)
            .filter { !locationPaths.contains($0.path) }
            .prefix(Self.recentLimit)
        if recents.isEmpty {
            recentMenu.addItem(disabledItem("No Recent Directories"))
        }
        for recent in recents {
            addRecentItems(recent.path, to: recentMenu)
        }
        menu.addItem(submenuItem("Recent", recentMenu))

        menu.addItem(.separator())

        if let error = store.loadError {
            let item = disabledItem("workspace.json could not be read")
            item.toolTip = error
            menu.addItem(item)
        }

        let open = NSMenuItem(title: "Open workspace.json", action: #selector(performMenuAction(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = MenuAction.openFile
        open.toolTip = store.fileURL.path
        menu.addItem(open)

        let reload = NSMenuItem(title: "Reload Workspace", action: #selector(performMenuAction(_:)), keyEquivalent: "")
        reload.target = self
        reload.representedObject = MenuAction.reload
        menu.addItem(reload)
    }

    private func addLocationItems(_ location: WorkspaceLocation, to menu: NSMenu, withShortcut: Bool) {
        let shortcut = withShortcut ? acceptedShortcut(location.shortcut) : nil
        let tooltip = WorkspaceDisplay.locationDetail(location)

        let primary = actionItem(
            title: WorkspaceDisplay.locationTitle(location),
            action: .location(location, .here),
            shortcut: shortcut
        )
        primary.toolTip = tooltip
        primary.image = symbolImage(location.icon ?? "folder")
        menu.addItem(primary)

        if let alternate = alternateItem(
            title: "\(WorkspaceDisplay.locationTitle(location)) in New Tab",
            action: .location(location, .newTab),
            shortcut: shortcut
        ) {
            alternate.toolTip = tooltip
            alternate.image = primary.image
            menu.addItem(alternate)
        }
    }

    /// Recent directories are learned from the shell, so they always open in
    /// a new tab (never typed into a terminal).
    private func addRecentItems(_ path: String, to menu: NSMenu) {
        let primary = actionItem(title: WorkspacePath.abbreviate(path), action: .recent(path, .newTab), shortcut: nil)
        primary.toolTip = "Open a new tab in \(path)"
        menu.addItem(primary)
    }

    private func commandItem(_ command: WorkspaceCommand, withShortcut: Bool) -> NSMenuItem {
        let shortcut = withShortcut ? acceptedShortcut(command.shortcut) : nil
        let item = actionItem(title: WorkspaceDisplay.commandTitle(command), action: .command(command), shortcut: shortcut)
        item.toolTip = command.confirm
            ? "\(command.command)  (press Enter to run)"
            : "\(command.command)  (runs immediately)"
        item.image = symbolImage("terminal")
        return item
    }

    private func actionItem(title: String, action: MenuAction, shortcut: WorkspaceShortcut?) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(performMenuAction(_:)),
            keyEquivalent: shortcut?.keyEquivalent ?? ""
        )
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
        item.target = self
        item.representedObject = action
        return item
    }

    /// An ⌥-alternate for `actionItem`. Without a shortcut the alternate has
    /// no key equivalent (it only appears while ⌥ is held in an open menu).
    /// With a (⌘) shortcut, the ⌥ variant must also be free in Ghostty;
    /// returns nil if it is taken or the shortcut already uses ⌥.
    private func alternateItem(title: String, action: MenuAction, shortcut: WorkspaceShortcut?) -> NSMenuItem? {
        guard let shortcut else {
            let item = actionItem(title: title, action: action, shortcut: nil)
            item.keyEquivalentModifierMask = .option
            item.isAlternate = true
            return item
        }
        guard shortcut.hasCommand, !shortcut.modifiers.contains(.option) else { return nil }
        let alternate = shortcut.with(modifiers: shortcut.modifiers.union(.option))
        guard isFree(alternate) else { return nil }
        let item = actionItem(title: title, action: action, shortcut: alternate)
        item.isAlternate = true
        return item
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    }

    // MARK: - Actions

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        switch action {
        case .location(let location, let mode):
            WorkspaceActions.open(location, mode: mode, store: store)
        case .recent(let path, let mode):
            WorkspaceActions.openRecent(path, mode: mode)
        case .command(let command):
            WorkspaceActions.run(command, store: store)
        case .openFile:
            store.openInEditor()
        case .reload:
            store.reload()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.representedObject is MenuAction
    }
}
