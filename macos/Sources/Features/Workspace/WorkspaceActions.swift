import AppKit
import GhosttyKit

/// The actions behind the Workspace palette entries and menu items.
///
/// Security:
/// - Only text from the user's own `workspace.json` is ever typed, checked
///   with `WorkspaceShell.isSafeToInsert`, and always visibly.
/// - Paths are typed (`cd '<path>'`) only if they pass
///   `WorkspaceShell.isSafeToType(path:)`; otherwise the directory is opened
///   in a new tab via `working_directory`, which never goes through a shell.
/// - Recent directories are learned from the shell (untrusted) and are never
///   typed; they always open via `working_directory`.
/// - Enter is pressed only when the shell sits at an empty primary prompt
///   (`SurfaceView.slimerIdlePrompt`, OSC 133 shell integration). Otherwise
///   commands are typed without Enter and "go to here" opens a new tab.
///   Nothing is ever sent to clear the user's input line.
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
        let path = location.expandedPath
        guard path.hasPrefix("/") else {
            reject("location \"\(location.name)\" path is not absolute after ~ expansion")
            return
        }
        store.recordUse(location: location)
        open(
            path: path,
            mode: mode,
            startup: location.trimmedStartupCommand.map { ($0, location.startupConfirm) },
            from: surfaceView
        )
    }

    /// Open a learned recent directory. Never typed into a shell: "here"
    /// becomes a new tab.
    static func openRecent(_ path: String, mode: OpenMode, from surfaceView: Ghostty.SurfaceView? = nil) {
        open(path: path, mode: mode == .here ? .newTab : mode, startup: nil, from: surfaceView)
    }

    /// Type a saved command into the focused terminal. Enter is pressed only
    /// when `confirm` is false and the shell is at a prompt.
    static func run(
        _ command: WorkspaceCommand,
        from surfaceView: Ghostty.SurfaceView? = nil,
        store: WorkspaceStore = .shared
    ) {
        guard WorkspaceShell.isSafeToInsert(command.command) else {
            reject("command \"\(command.name)\" contains control or format characters")
            return
        }

        var cwdPath: String?
        if let cwd = command.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            let expanded = WorkspacePath.expand(cwd)
            guard expanded.hasPrefix("/") else {
                reject("command \"\(command.name)\" cwd is not absolute after ~ expansion")
                return
            }
            cwdPath = expanded
        }

        // A cwd that cannot be typed safely: open a new tab there and let the
        // new shell receive the command as initial input. The path is never
        // typed.
        if let cwdPath, !WorkspaceShell.isSafeToType(path: cwdPath) {
            guard WorkspaceShell.isSafeToInsert(cwdPath) else {
                reject("command \"\(command.name)\" cwd contains control or format characters")
                return
            }
            store.recordUse(command: command)
            openNewTab(path: cwdPath, startup: (command.command, command.confirm), from: surfaceView)
            return
        }

        guard let target = targetSurface(preferring: surfaceView),
              let controller = BaseTerminalController.controller(owning: target) else {
            NSSound.beep()
            return
        }

        var text = command.command
        if let cwdPath {
            text = WorkspaceShell.cdCommand(to: cwdPath) + " && " + text
        }
        store.recordUse(command: command)

        // Not at an empty prompt (a program is running, text is already typed,
        // or no shell integration): insert the text only, never Enter.
        let idle = target.slimerIdlePrompt
        controller.performAction(
            WorkspaceShell.textBindingAction(text, pressEnter: idle && !command.confirm),
            on: target
        )
    }

    // MARK: - Opening directories

    private static func open(
        path: String,
        mode: OpenMode,
        startup: (command: String, confirm: Bool)?,
        from surfaceView: Ghostty.SurfaceView?
    ) {
        guard path.hasPrefix("/") else {
            reject("path is not absolute")
            return
        }
        guard WorkspaceShell.isSafeToInsert(path) else {
            reject("path contains control or format characters")
            return
        }

        switch mode {
        case .here:
            guard let target = targetSurface(preferring: surfaceView),
                  let controller = BaseTerminalController.controller(owning: target) else {
                // Nothing to type into: open a window there instead.
                open(path: path, mode: .newWindow, startup: startup, from: nil)
                return
            }
            // Fall back to a new tab when the path can't be typed safely or the
            // shell is not at an empty prompt (Enter would run other text).
            guard WorkspaceShell.isSafeToType(path: path), target.slimerIdlePrompt else {
                openNewTab(path: path, startup: nil, from: target)
                return
            }
            controller.performAction(
                WorkspaceShell.textBindingAction(WorkspaceShell.cdCommand(to: path), pressEnter: true),
                on: target
            )

        case .newSplit:
            if let target = targetSurface(preferring: surfaceView),
               let controller = BaseTerminalController.controller(owning: target) {
                controller.newSplit(
                    at: target,
                    direction: .right,
                    baseConfig: surfaceConfiguration(path: path, startup: startup)
                )
            } else {
                open(path: path, mode: .newWindow, startup: startup, from: nil)
            }

        case .newTab:
            openNewTab(path: path, startup: startup, from: surfaceView)

        case .newWindow:
            guard let ghostty else { return }
            _ = TerminalController.newWindow(
                ghostty,
                withBaseConfig: surfaceConfiguration(path: path, startup: startup)
            )
        }
    }

    private static func openNewTab(
        path: String,
        startup: (command: String, confirm: Bool)?,
        from surfaceView: Ghostty.SurfaceView?
    ) {
        guard let ghostty else { return }
        let parent = targetSurface(preferring: surfaceView)?.window
            ?? TerminalController.preferredParent?.window
        _ = TerminalController.newTab(
            ghostty,
            from: parent,
            withBaseConfig: surfaceConfiguration(path: path, startup: startup)
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

    /// A configuration for a new surface in `path`. A startup command is typed
    /// into the new shell as initial input, followed by a newline only when
    /// the user opted out of confirmation.
    static func surfaceConfiguration(
        path: String,
        startup: (command: String, confirm: Bool)?
    ) -> Ghostty.SurfaceConfiguration {
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = path
        if let startup {
            if WorkspaceShell.isSafeToInsert(startup.command) {
                config.initialInput = startup.confirm ? startup.command : startup.command + "\n"
            } else {
                reject("startup command contains control or format characters")
            }
        }
        return config
    }

    private static func reject(_ reason: String) {
        WorkspaceStore.logger.error("workspace action rejected: \(reason, privacy: .public)")
        NSSound.beep()
    }
}
