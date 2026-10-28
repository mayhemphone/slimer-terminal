import Cocoa
import Combine
import SwiftUI
import GhosttyKit

// slimer: tab support for the quick terminal ("drawer").
//
// How tabs interact with BaseTerminalController
// ---------------------------------------------
// The base controller owns exactly one `surfaceTree` and every split/focus/undo
// path assumes that tree is the whole window. We keep that invariant: the
// controller's `surfaceTree` is always the *selected* tab's tree. Switching tabs
// swaps the tree (no surface is destroyed). Background tabs keep their trees in
// `QuickTerminalTab.surfaceTree` and are:
//
//   * told they lost focus and are occluded (so libghostty stops rendering them),
//   * still "owned" by this controller via `ownsSurface(_:)` so AppleScript, App
//     Intents and `controller(owning:)` can find them,
//   * pruned when a process exits (`onCloseBackgroundSurface`), and removed
//     entirely when they become empty.
//
// Undo: the base controller's split undo closures assign `surfaceTree` directly
// and would land on whichever tab is selected at undo time, so split undo is
// dropped on every tab switch. Close-tab undo is registered separately and keeps
// the tab (and its running surfaces) alive until it expires, like upstream's
// close-tab undo for normal windows.

extension QuickTerminalController {
    typealias Tab = QuickTerminalTab<Ghostty.SurfaceView>

    /// Number of drawer tabs. Used for `goto_tab`/`move_tab` performability.
    var tabCount: Int { tabs.count }

    // MARK: Setup

    /// Called once from init. Observers are removed in the controller's deinit.
    func setupTabs() {
        tabBarModel.onSelect = { [weak self] id in self?.selectTab(id: id) }
        tabBarModel.onClose = { [weak self] id in
            guard let self, let index = tabs.index(of: id), let tab = tabs[index] else { return }
            closeTab(tab)
        }
        tabBarModel.onNew = { [weak self] in self?.newTab() }

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onGotoTab(_:)),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onMoveTab(_:)),
            name: .ghosttyMoveTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseTab(_:)),
            name: .ghosttyCloseTab,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onCloseBackgroundSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onPresentBackgroundTerminal(_:)),
            name: Ghostty.Notification.ghosttyPresentTerminal,
            object: nil)
    }

    /// Push config-derived appearance into the tab bar. Called from syncAppearance.
    func syncTabBar(config: Ghostty.Config, visibility: QuickTerminalTabBar) {
        tabBarModel.update(visibility: visibility)
        tabBarModel.update(
            backgroundColor: NSColor(config.backgroundColor),
            backgroundOpacity: isBackgroundOpaque ? 1 : config.backgroundOpacity)
    }

    // MARK: Hooks from the controller overrides

    /// Keep the selected tab's tree in sync with `surfaceTree`.
    ///
    /// Returns true when the change was fully handled here and the drawer must not
    /// hide (an emptied tab was replaced by a neighbor).
    func tabsDidChangeSurfaceTree(to tree: SplitTree<Ghostty.SurfaceView>) -> Bool {
        // A tab switch assigns the tree itself; nothing to sync.
        if isSwitchingTabs { return false }

        if tree.isEmpty {
            guard let selected = tabs.selected else { return false }
            tabObservers[selected.id] = nil

            if tabs.neighborIndex(forRemoving: tabs.selectedIndex) != nil {
                // Another tab exists: drop the emptied one and show the neighbor
                // instead of hiding the drawer. The model moves the selection to
                // the neighbor; selectTab swaps the tree in.
                tabs.remove(id: selected.id)
                selectTab(at: tabs.selectedIndex)
                return true
            }

            // Last tab: upstream behavior. The drawer hides and a fresh tab is
            // created the next time it is shown.
            tabs.remove(id: selected.id)
            refreshTabBar()
            return false
        }

        guard let selected = tabs.selected else {
            // First tree (initial show, restoration, undo into an empty drawer):
            // wrap it in a tab.
            let tab = Tab(surfaceTree: tree, focusedSurface: focusedSurface)
            tabs.insert(tab)
            observeTab(tab)
            refreshTabBar()
            return false
        }

        selected.surfaceTree = tree
        if let focused = selected.focusedSurface, !tree.contains(focused) {
            selected.focusedSurface = tree.first
        }
        // Membership may have changed (split added/removed), so re-subscribe.
        observeTab(selected)
        return false
    }

    /// Remember which surface is focused in the selected tab so switching back
    /// restores it, and follow that surface's title.
    func tabsFocusedSurfaceDidChange(to view: Ghostty.SurfaceView?) {
        guard let view, let selected = tabs.selected, selected.contains(view) else { return }
        guard selected.focusedSurface !== view else { return }
        selected.focusedSurface = view
        observeTab(selected)
    }

    /// The title override (`set_tab_title`, `prompt_tab_title`) is per tab.
    func tabsTitleOverrideDidChange() {
        guard let selected = tabs.selected else { return }
        selected.titleOverride = titleOverride
        refreshTabBar()
    }

    // MARK: Selection

    /// Bring the tab containing `view` forward. Returns false if no tab owns it.
    @discardableResult
    func selectTab(containing view: Ghostty.SurfaceView) -> Bool {
        guard let index = tabs.index(containing: view) else { return false }
        if index != tabs.selectedIndex {
            selectTab(at: index)
        }
        return true
    }

    func selectTab(id: Tab.ID) {
        guard let index = tabs.index(of: id) else { return }
        selectTab(at: index)
    }

    /// Make the tab at `index` the visible one, swapping its tree into
    /// `surfaceTree`. Safe to call for the already-selected index when the tree
    /// has not been shown yet (e.g. after inserting a new tab).
    func selectTab(at index: Int) {
        guard let newTab = tabs[index] else { return }
        if index == tabs.selectedIndex && surfaceTree.root == newTab.surfaceTree.root {
            return
        }

        if let oldTab = tabs.selected, oldTab !== newTab {
            oldTab.focusedSurface = focusedSurface ?? oldTab.focusedSurface
            for view in oldTab.surfaceTree {
                sendToBackground(view)
            }
        }

        tabs.select(index: index)

        // See the file comment: split undo targets this controller and assigns
        // `surfaceTree` directly, so it cannot survive a tab switch.
        undoManager?.removeAllActions(withTarget: self)

        isSwitchingTabs = true
        surfaceTree = newTab.surfaceTree
        isSwitchingTabs = false

        titleOverride = newTab.titleOverride

        let target = newTab.focusedSurface ?? newTab.surfaceTree.first
        focusedSurface = target
        if let target {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: target)
            }
        }

        refreshTabBar()
    }

    /// A surface that is no longer in the visible tree must not think it is
    /// focused, and should stop rendering until it is shown again. The base
    /// controller restores both when the tree comes back.
    private func sendToBackground(_ view: Ghostty.SurfaceView) {
        view.focusDidChange(false)
        if let surface = view.surface, view.isWindowVisible {
            ghostty_surface_set_occlusion(surface, false)
            view.isWindowVisible = false
        }
    }

    // MARK: New / Close

    /// Create a new drawer tab after the selected one and show it.
    func newTab(baseConfig base: Ghostty.SurfaceConfiguration? = nil) {
        guard let app = ghostty.app else { return }
        var config = base ?? Ghostty.SurfaceConfiguration()
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"

        let view = Ghostty.SurfaceView(app, baseConfig: config)
        let tab = Tab(view: view)
        let index = tabs.insert(tab, select: false)
        observeTab(tab)
        selectTab(at: index)
        if !visible {
            animateIn()
        }
    }

    /// Close a tab, confirming if any of its surfaces has a running process.
    ///
    /// The only tab is never closed: the drawer hides and keeps its shell, which
    /// is what upstream does for `close_tab`/`close_surface` in the quick terminal.
    func closeTab(_ tab: Tab, withConfirmation: Bool = true) {
        guard let index = tabs.index(of: tab.id) else { return }
        guard tabs.count > 1 else {
            animateOut()
            return
        }

        guard withConfirmation, tab.surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            removeTab(tab, registerUndo: true)
            return
        }

        // Show the tab being closed so the confirmation makes sense.
        selectTab(at: index)
        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) { [weak self] in
            self?.removeTab(tab, registerUndo: true)
        }
    }

    /// Remove a tab without confirmation. Selected tabs hand off to a neighbor
    /// first so the base controller never observes an empty tree.
    func removeTab(_ tab: Tab, registerUndo: Bool) {
        guard let index = tabs.index(of: tab.id) else { return }
        guard tabs.count > 1 else {
            animateOut()
            return
        }

        if index == tabs.selectedIndex, let neighbor = tabs.neighborIndex(forRemoving: index) {
            selectTab(at: neighbor)
        }

        guard let removed = tabs.remove(id: tab.id) else { return }
        tabObservers[removed.id] = nil
        for view in removed.surfaceTree {
            sendToBackground(view)
        }

        // The undo closure retains the tab, and therefore its surfaces, until it
        // expires. Target `ghostty` (as upstream does for close-tab) so the
        // controller-targeted cleanup in selectTab leaves it alone.
        if registerUndo, let undoManager {
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(
                withTarget: ghostty,
                expiresAfter: undoExpiration
            ) { [weak self] _ in
                guard let self else { return }
                restoreTab(removed, at: index)

                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: undoExpiration
                ) { [weak self] _ in
                    self?.removeTab(removed, registerUndo: true)
                }
            }
        }

        refreshTabBar()
    }

    /// Reinsert a previously removed tab (undo of close-tab) and show it.
    func restoreTab(_ tab: Tab, at index: Int) {
        let target = tabs.insert(tab, at: index, select: false)
        observeTab(tab)
        selectTab(at: target)
        if !visible {
            animateIn()
        }
    }

    // MARK: Tab bar

    /// Follow the tab's focused-surface title and any bell in the tab. Cheap: one
    /// subscription per tab, rebuilt only when focus or membership changes.
    func observeTab(_ tab: Tab) {
        guard let focused = tab.focusedSurface ?? tab.surfaceTree.first else {
            tabObservers[tab.id] = nil
            return
        }

        let bells = tab.surfaceTree
            .valuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)
            .map { $0.values.contains(true) }

        tabObservers[tab.id] = focused.$title
            .combineLatest(bells)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak tab] title, bell in
                guard let self, let tab else { return }
                tab.title = title
                tab.bell = bell
                refreshTabBar()
            }
    }

    func refreshTabBar() {
        let items = tabs.tabs.map {
            QuickTerminalTabBarModel.Item(id: $0.id, title: $0.displayTitle, bell: $0.bell, color: nil)
        }
        tabBarModel.update(items: items, selectedID: tabs.selected?.id)
    }

    // MARK: Notifications

    @objc func onGotoTab(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView,
              surfaceTree.contains(target) else { return }
        guard let tabEnum = notification.userInfo?[Ghostty.Notification.GotoTabKey] as? ghostty_action_goto_tab_e else { return }

        let goto: QuickTerminalTabs<Ghostty.SurfaceView>.Goto
        switch tabEnum {
        case GHOSTTY_GOTO_TAB_PREVIOUS: goto = .previous
        case GHOSTTY_GOTO_TAB_NEXT: goto = .next
        case GHOSTTY_GOTO_TAB_LAST: goto = .last
        default:
            // The configured value is 1-indexed.
            guard tabEnum.rawValue >= 1 else { return }
            goto = .absolute(Int(tabEnum.rawValue))
        }

        guard let index = tabs.index(for: goto) else { return }
        selectTab(at: index)
    }

    @objc func onMoveTab(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView,
              surfaceTree.contains(target) else { return }
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab,
              action.amount != 0 else { return }

        let from = tabs.selectedIndex
        let to = tabs.movedIndex(from: from, by: action.amount)
        guard to != from else { return }
        tabs.move(from: from, to: to)
        refreshTabBar()
    }

    @objc func onCloseTab(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView,
              let tab = tabs.tab(containing: target) else { return }
        closeTab(tab)
    }

    /// A surface in a background tab asked to close (normally because its
    /// process exited). The base controller ignores surfaces outside the visible
    /// tree, so prune the background tree here.
    @objc func onCloseBackgroundSurface(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard !surfaceTree.contains(target),
              let index = tabs.index(containing: target),
              let tab = tabs[index] else { return }

        let alive = (notification.userInfo?["process_alive"] as? Bool) ?? false
        if alive {
            // Needs confirmation: bring the tab forward and use the normal path.
            selectTab(at: index)
            closeSurface(target, withConfirmation: true)
            return
        }

        guard let node = tab.surfaceTree.root?.node(view: target) else { return }
        let newTree = tab.surfaceTree.removing(node)
        if newTree.isEmpty {
            removeTab(tab, registerUndo: false)
            return
        }

        tab.surfaceTree = newTree
        if tab.focusedSurface == nil || tab.focusedSurface === target {
            tab.focusedSurface = newTree.first
        }
        observeTab(tab)
        refreshTabBar()
    }

    /// `present_terminal` (e.g. clicking a notification) for a surface in a
    /// background tab: select that tab, then focus and highlight the surface.
    @objc func onPresentBackgroundTerminal(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard !surfaceTree.contains(target),
              let index = tabs.index(containing: target) else { return }

        selectTab(at: index)
        if !visible {
            animateIn()
        }
        Ghostty.moveFocus(to: target, delay: 0.1)
        target.highlight()
    }
}

extension NSWindow {
    /// slimer: number of tabs for `goto_tab`/`move_tab` performability. Quick
    /// terminal windows count their drawer tabs; everything else uses the AppKit
    /// tab group as before.
    var slimerTabCount: Int {
        if let quick = windowController as? QuickTerminalController {
            return quick.tabCount
        }
        return tabGroup?.windows.count ?? 0
    }
}
