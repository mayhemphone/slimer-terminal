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

        // Go to: <name> (path)
        for location in document.rankedLocations(now: now) {
            let path = WorkspacePath.abbreviate(location.expandedPath)
            let symbols = location.shortcut.flatMap { WorkspaceShortcut(parsing: $0)?.symbols }
            options.append(CommandOption(
                title: "Go to: \(location.name)",
                subtitle: path,
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
                    title: "Go to (new tab): \(location.name)",
                    subtitle: path,
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
            let symbols = command.shortcut.flatMap { WorkspaceShortcut(parsing: $0)?.symbols }
            options.append(CommandOption(
                title: "Run: \(command.name)",
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

        // Recent: <path> (skip directories that already are locations)
        let locationPaths = Set(document.locations.map(\.expandedPath))
        let recents = document.rankedRecent(now: now)
            .filter { !locationPaths.contains($0.path) }
            .prefix(recentLimit)
        for recent in recents {
            let path = recent.path
            options.append(CommandOption(
                title: "Recent: \(WorkspacePath.abbreviate(path))",
                description: goToDescription,
                leadingIcon: "clock"
            ) {
                WorkspaceActions.open(path: path, mode: optionHeld ? .newTab : .here, from: surfaceView)
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
