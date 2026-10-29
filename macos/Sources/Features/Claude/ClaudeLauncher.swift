import AppKit
import GhosttyKit

/// Finds the `claude` binary and opens Claude Code in new tabs or splits.
///
/// Detection never runs a shell: it stats a fixed list of install locations and
/// then the app's own `PATH` entries. The first executable regular file wins.
/// Launching uses Ghostty's normal new-tab / new-split notifications with a base
/// config whose `command` is the absolute (shell-quoted) path to `claude`.
@MainActor
enum ClaudeLauncher {
    /// What to start.
    enum Mode: Equatable {
        case new
        case continueLast
        case resume

        var arguments: [String] {
            switch self {
            case .new: return []
            case .continueLast: return ["--continue"]
            case .resume: return ["--resume"]
            }
        }
    }

    /// Where to start it.
    enum Placement: Equatable {
        case tab
        case splitRight
    }

    static let installURL = URL(string: "https://claude.com/claude-code")

    // MARK: Detection

    private static var cachedBinary: URL?
    private static var lastMiss: Date?

    /// How long a failed lookup is remembered, so menus can ask cheaply.
    static let missCacheLifetime: TimeInterval = 30

    /// The located `claude` binary (cached; see `resolveBinary(validate:)`).
    static var binary: URL? { resolveBinary(validate: false) }

    /// Whether Claude Code was found. Cheap: served from the cache. Menus ask
    /// this when they are built; launching re-validates.
    static var isInstalled: Bool { binary != nil }

    /// Look up the binary. A hit is cached until a launch finds it gone
    /// (`validate: true` re-checks the cached file); a miss is cached for
    /// `missCacheLifetime`, so installing Claude Code while Slimer runs is
    /// picked up without a `stat` on every menu render.
    static func resolveBinary(validate: Bool) -> URL? {
        if let cached = cachedBinary {
            if !validate || locate(candidates: [cached.path]) != nil { return cached }
            cachedBinary = nil
        } else if !validate, let lastMiss, Date().timeIntervalSince(lastMiss) < missCacheLifetime {
            return nil
        }
        let found = locate(candidates: defaultCandidates())
        cachedBinary = found
        lastMiss = found == nil ? Date() : nil
        return found
    }

    /// Install locations in priority order, followed by the absolute entries of
    /// `pathEnvironment` (the app's environment, not a login shell's).
    nonisolated static func defaultCandidates(
        home: String = NSHomeDirectory(),
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) -> [String] {
        var candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        for entry in (pathEnvironment ?? "").split(separator: ":") where entry.hasPrefix("/") {
            let candidate = "\(entry)/claude"
            if !candidates.contains(candidate) { candidates.append(candidate) }
        }
        return candidates
    }

    /// The first candidate that is an executable regular file (symlinks are
    /// followed). Returned unresolved, so a versioned install behind
    /// `~/.local/bin/claude` keeps working after an update.
    nonisolated static func locate(candidates: [String], fileManager: FileManager = .default) -> URL? {
        for path in candidates {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// The shell command line Ghostty runs for `mode`: the quoted absolute binary
    /// path plus fixed flags. Ghostty runs `command` through the user's shell, so
    /// the path must be quoted (home directories can contain spaces).
    nonisolated static func commandLine(binary: URL, mode: Mode) -> String? {
        guard let quoted = try? GitShellQuoting.quote(binary.path) else { return nil }
        return ([quoted] + mode.arguments).joined(separator: " ")
    }

    // MARK: Launching

    /// Open Claude Code next to `surfaceView`, in its working directory.
    /// Without Claude installed this opens the install page instead.
    static func launch(_ mode: Mode, placement: Placement, from surfaceView: Ghostty.SurfaceView) {
        guard let binary = resolveBinary(validate: true) else {
            openInstallPage()
            return
        }
        guard let command = commandLine(binary: binary, mode: mode) else {
            // A path with `'`, `\` or control characters cannot be typed safely.
            NSSound.beep()
            return
        }

        let context = placement == .tab ? GHOSTTY_SURFACE_CONTEXT_TAB : GHOSTTY_SURFACE_CONTEXT_SPLIT
        var config = SlimerStatusBarActions.inheritedConfig(from: surfaceView, context: context)
        config.command = command
        if let pwd = surfaceView.pwd, !pwd.isEmpty {
            config.workingDirectory = pwd
        }
        // npm installs are `#!/usr/bin/env node` scripts; node usually sits next to
        // them (Homebrew). Put the binary's directory first on PATH for this surface.
        let binaryDirectory = binary.deletingLastPathComponent().path
        let inheritedPath = config.environmentVariables["PATH"]
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        config.environmentVariables["PATH"] = "\(binaryDirectory):\(inheritedPath)"

        switch placement {
        case .tab:
            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyNewTab,
                object: surfaceView,
                userInfo: [Ghostty.Notification.NewSurfaceConfigKey: config]
            )
        case .splitRight:
            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyNewSplit,
                object: surfaceView,
                userInfo: [
                    "direction": GHOSTTY_SPLIT_DIRECTION_RIGHT,
                    Ghostty.Notification.NewSurfaceConfigKey: config,
                ]
            )
        }
    }

    static func openInstallPage() {
        guard let url = installURL, url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
}
