import AppKit
import SwiftUI

/// Owns the Settings window (opened with Cmd+, from the app menu).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let store = SettingsConfigStore.shared

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.identifier = NSUserInterfaceItemIdentifier("SlimerSettings")
        window.setFrameAutosaveName("SlimerSettings")
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SlimerSettingsView(config: store))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        store.load()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Don't lose an edit made less than the debounce interval ago.
        store.flush()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Pick up hand edits made while the window was in the background.
        store.load()
    }
}
