import AppKit
import GhosttyKit

/// The actions behind the Workspace palette entries and menu items.
///
/// Security: everything typed into a terminal here comes from the user's own
/// `workspace.json`, is checked with `WorkspaceShell.isSafeToInsert` and is
/// typed visibly. Enter is pressed only for `cd` and for commands the user
/// marked `confirm: false`.
///
/// Main thread only.
enum WorkspaceActions {
    enum OpenMode {
        case here
        case newTab
        case newSplit
        case newWindow
    }

    /// Open a configured location and record its use.
    static func open(
        _ location: WorkspaceLocation,
        mode: OpenMode,
        from surfaceView: Ghostty.SurfaceView? = nil,
        store: WorkspaceStore = .shared
    ) {
        store.recordUse(location: location)
        open(
            path: location.expandedPath,
            mode: mode,
            startupCommand: location.startupCommand,
            from: surfaceView
        )
    }

    /// Open an arbitrary (already expanded) directory path.
    static func open(
        path: String,
        mode: OpenMode,
        startupCommand: String? = nil,
        from surfaceView: Ghostty.SurfaceView? = nil
    ) {
        guard WorkspaceShell.isSafeToInsert(path) else {
            reject("path contains control or bidi characters")
            return
        }

        switch mode {
        case .here:
            guard let target = targetSurface(preferring: surfaceView),
                  let controller = BaseTerminalController.controller(owning: target) else {
                // Nothing to type into: open a window there instead.
                open(path: path, mode: .newWindow, startupCommand: startupCommand)
                return
            }
            let action = WorkspaceShell.textBindingAction(
                WorkspaceShell.cdCommand(to: path),
                pressEnter: true
            )
            controller.performAction(action, on: target)

        case .newSplit:
            if let target = targetSurface(preferring: surfaceView),
               let controller = BaseTerminalController.controller(owning: target) {
                controller.newSplit(
                    at: target,
                    direction: .right,
                    baseConfig: surfaceConfiguration(path: path, startupCommand: startupCommand)
                )
            } else {
                open(path: path, mode: .newWindow, startupCommand: startupCommand)
            }

        case .newTab:
            guard let ghostty else { return }
            let parent = targetSurface(preferring: surfaceView)?.window
                ?? TerminalController.preferredParent?.window
            _ = TerminalController.newTab(
                ghostty,
                from: parent,
                withBaseConfig: surfaceConfiguration(path: path, startupCommand: startupCommand)
            )

        case .newWindow:
            guard let ghostty else { return }
            _ = TerminalController.newWindow(
                ghostty,
                withBaseConfig: surfaceConfiguration(path: path, startupCommand: startupCommand)
            )
        }
    }

    /// Type a saved command into the focused terminal. Enter is pressed only
    /// when `confirm` is false.
    static func run(
        _ command: WorkspaceCommand,
        from surfaceView: Ghostty.SurfaceView? = nil,
        store: WorkspaceStore = .shared
    ) {
        var text = command.command
        if let cwd = command.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            text = WorkspaceShell.cdCommand(to: WorkspacePath.expand(cwd)) + " && " + text
        }
        guard WorkspaceShell.isSafeToInsert(text) else {
            reject("command \"\(command.name)\" contains control or bidi characters")
            return
        }
        guard let target = targetSurface(preferring: surfaceView),
              let controller = BaseTerminalController.controller(owning: target) else {
            NSSound.beep()
            return
        }
        store.recordUse(command: command)
        controller.performAction(
            WorkspaceShell.textBindingAction(text, pressEnter: !command.confirm),
            on: target
        )
    }

    // MARK: - Helpers

    private static var ghostty: Ghostty.App? {
        (NSApp.delegate as? AppDelegate)?.ghostty
    }

    /// The surface to act on: the explicit one, else the focused surface of
    /// the key window, else of the main window, else of the preferred parent.
    private static func targetSurface(preferring surfaceView: Ghostty.SurfaceView?) -> Ghostty.SurfaceView? {
        if let surfaceView { return surfaceView }
        for window in [NSApp.keyWindow, NSApp.mainWindow] {
            if let controller = window?.windowController as? BaseTerminalController,
               let surface = controller.focusedSurface {
                return surface
            }
        }
        return TerminalController.preferredParent?.focusedSurface
    }

    private static func surfaceConfiguration(path: String, startupCommand: String?) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path
        if let startupCommand = startupCommand?.trimmingCharacters(in: .whitespaces),
           !startupCommand.isEmpty {
            if WorkspaceShell.isSafeToInsert(startupCommand) {
                // Typed into the new shell once it starts, followed by Enter.
                config.initialInput = startupCommand + "\n"
            } else {
                reject("startup command contains control or bidi characters")
            }
        }
        return config
    }

    private static func reject(_ reason: String) {
        WorkspaceStore.logger.error("workspace action rejected: \(reason, privacy: .public)")
        NSSound.beep()
    }
}
