import SwiftUI

/// Builds the Workspace entries for the terminal command palette:
/// `Go to: …`, `Run: …` and `Recent: …`. Pinned items come first, then
/// frecency order (see `WorkspaceDocument.ranked*`). Main thread only.
enum WorkspacePaletteOptions {
    /// How many recent directories to show.
    static let recentLimit = 8

    private static let goToDescription = "Change directory in this terminal. Hold ⌥ to open in a new tab instead."

    static func options(
        for surfaceView: Ghostty.SurfaceView,
        store: WorkspaceStore = .shared
    ) -> [CommandOption] {
        let now = Date()
        let document = store.document
        var options: [CommandOption] = []

        // Only shortcuts that the menu actually registers are shown.
        let isBound: (WorkspaceShortcut) -> Bool = { shortcut in
            guard let surface = surfaceView.surfaceModel else { return false }
            return WorkspaceShortcut.isGhosttyBinding(shortcut, on: surface)
        }

        // Go to: <name> (path)
        for location in document.rankedLocations(now: now) {
            let detail = WorkspaceDisplay.locationDetail(location)
            let title = WorkspaceDisplay.locationTitle(location)
            let symbols = WorkspaceShortcut.accepted(location.shortcut, log: false, isBound: isBound)?.symbols
            options.append(CommandOption(
                title: "Go to: \(title)",
                subtitle: detail,
                description: goToDescription,
                symbols: symbols,
                leadingIcon: location.icon ?? "folder",
                leadingColor: color(location.color),
                emphasis: location.pinned
            ) {
                WorkspaceActions.open(location, mode: optionHeld ? .newTab : .here, from: surfaceView, store: store)
            })

            // Pinned locations also get an explicit new-tab entry since the
            // palette cannot show modifier-dependent actions.
            if location.pinned {
                options.append(CommandOption(
                    title: "Go to (new tab): \(title)",
                    subtitle: detail,
                    description: "Open a new tab in this directory.",
                    leadingIcon: "plus.rectangle.on.folder",
                    leadingColor: color(location.color)
                ) {
                    WorkspaceActions.open(location, mode: .newTab, from: surfaceView, store: store)
                })
            }
        }

        // Run: <name>
        for command in document.rankedCommands(now: now) {
            var subtitle = command.command
            if let cwd = command.cwd, !cwd.isEmpty {
                subtitle += "  (in \(WorkspacePath.abbreviate(WorkspacePath.expand(cwd))))"
            }
            let symbols = WorkspaceShortcut.accepted(command.shortcut, log: false, isBound: isBound)?.symbols
            options.append(CommandOption(
                title: "Run: \(WorkspaceDisplay.commandTitle(command))",
                subtitle: subtitle,
                description: command.confirm
                    ? "Type the command into this terminal; press Enter to run it."
                    : "Type the command into this terminal and run it.",
                symbols: symbols,
                leadingIcon: "terminal",
                badge: command.confirm ? nil : "auto-run",
                emphasis: command.pinned
            ) {
                WorkspaceActions.run(command, from: surfaceView, store: store)
            })
        }

        // Recent: <path> (skip directories that already are locations).
        // Learned from the shell, so these always open in a new tab and are
        // never typed into a terminal.
        let locationPaths = Set(document.locations.map(\.expandedPath))
        let recents = document.rankedRecent(now: now)
            .filter { !locationPaths.contains($0.path) }
            .prefix(recentLimit)
        for recent in recents {
            let path = recent.path
            options.append(CommandOption(
                title: "Recent: \(WorkspacePath.abbreviate(path))",
                description: "Open a new tab in this directory.",
                leadingIcon: "clock"
            ) {
                WorkspaceActions.openRecent(path, mode: .newTab, from: surfaceView)
            })
        }

        return options
    }

    /// Whether Option is held right now (checked when the action fires, so
    /// ⌥-click and ⌥-Enter both open in a new tab).
    private static var optionHeld: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private static func color(_ hex: String?) -> Color? {
        guard let hex, let nsColor = NSColor(hex: hex) else { return nil }
        return Color(nsColor: nsColor)
    }
}
