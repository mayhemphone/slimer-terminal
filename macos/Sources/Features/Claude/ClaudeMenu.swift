import AppKit
import SwiftUI

/// The status bar's Claude button: click opens Claude Code in a new tab in the
/// surface's directory, Option-click opens it in a split to the right, and the
/// chevron menu offers continue/resume.
struct ClaudeButton: View {
    @ObservedObject var model: SlimerStatusBarModel

    var body: some View {
        Menu {
            ClaudeMenuItems(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                Text("Claude")
            }
            .foregroundColor(.secondary)
        } primaryAction: {
            guard let surfaceView = model.surfaceView else { return }
            let placement: ClaudeLauncher.Placement = NSEvent.modifierFlags.contains(.option) ? .splitRight : .tab
            ClaudeLauncher.launch(.new, placement: placement, from: surfaceView)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Claude Code here (⌥-click: split right)")
        .accessibilityLabel("Claude Code")
    }
}

/// Menu items shared by the button's menu.
struct ClaudeMenuItems: View {
    @ObservedObject var model: SlimerStatusBarModel

    var body: some View {
        if ClaudeLauncher.isInstalled {
            Button("Claude Here (New Tab)") { launch(.new, .tab) }
            Button("Claude Here (Split Right)") { launch(.new, .splitRight) }
            Divider()
            Button("Continue Last (claude --continue)") { launch(.continueLast, .tab) }
            Button("Resume… (claude --resume)") { launch(.resume, .tab) }
        } else {
            Button("Claude Code Not Installed") {}
                .disabled(true)
            Button("Install Claude Code…") { ClaudeLauncher.openInstallPage() }
        }
    }

    private func launch(_ mode: ClaudeLauncher.Mode, _ placement: ClaudeLauncher.Placement) {
        guard let surfaceView = model.surfaceView else { return }
        ClaudeLauncher.launch(mode, placement: placement, from: surfaceView)
    }
}

/// App-level "Claude" submenu in the File menu. Installed once from
/// `AppDelegate.applicationDidFinishLaunching` (one `// slimer:` line); items act
/// on the focused surface of the key terminal window.
@MainActor
final class SlimerClaudeMenu: NSObject, NSMenuDelegate {
    static let shared = SlimerClaudeMenu()

    private var installed = false

    static func install() {
        shared.install()
    }

    private func install() {
        guard !installed, let mainMenu = NSApp.mainMenu else { return }
        let fileItem = mainMenu.items.first { $0.submenu?.title == "File" } ?? mainMenu.item(withTitle: "File")
        guard let fileMenu = fileItem?.submenu else { return }
        installed = true

        let submenu = NSMenu(title: "Claude")
        submenu.delegate = self
        let item = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Claude")

        // After the "New Tab" item when present, else at the end.
        let anchor = fileMenu.items.firstIndex { $0.title == "New Tab" }
        if let anchor {
            fileMenu.insertItem(item, at: anchor + 1)
        } else {
            fileMenu.addItem(.separator())
            fileMenu.addItem(item)
        }
    }

    // Rebuilt on open so the installed check is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let surface = focusedSurface()
        guard ClaudeLauncher.isInstalled else {
            let missing = NSMenuItem(title: "Claude Code Not Installed", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
            menu.addItem(makeItem("Install Claude Code…", #selector(installClaude(_:)), enabled: true))
            return
        }
        let enabled = surface != nil
        menu.addItem(makeItem("Claude Here (New Tab)", #selector(newTab(_:)), enabled: enabled))
        menu.addItem(makeItem("Claude Here (Split Right)", #selector(splitRight(_:)), enabled: enabled))
        menu.addItem(.separator())
        menu.addItem(makeItem("Continue Last Session", #selector(continueLast(_:)), enabled: enabled))
        menu.addItem(makeItem("Resume Session…", #selector(resume(_:)), enabled: enabled))
    }

    private func makeItem(_ title: String, _ action: Selector, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func focusedSurface() -> Ghostty.SurfaceView? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in windows {
            if let controller = window.windowController as? BaseTerminalController,
               let surface = controller.focusedSurface {
                return surface
            }
        }
        return nil
    }

    private func launch(_ mode: ClaudeLauncher.Mode, _ placement: ClaudeLauncher.Placement) {
        guard let surface = focusedSurface() else { return }
        ClaudeLauncher.launch(mode, placement: placement, from: surface)
    }

    @objc private func newTab(_ sender: Any?) { launch(.new, .tab) }
    @objc private func splitRight(_ sender: Any?) { launch(.new, .splitRight) }
    @objc private func continueLast(_ sender: Any?) { launch(.continueLast, .tab) }
    @objc private func resume(_ sender: Any?) { launch(.resume, .tab) }
    @objc private func installClaude(_ sender: Any?) { ClaudeLauncher.openInstallPage() }
}
