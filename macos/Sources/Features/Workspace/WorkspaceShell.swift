import Foundation

/// Shell text helpers for the Workspace feature. Everything that ends up in a
/// terminal goes through here so quoting and safety checks live in one place.
enum WorkspaceShell {
    /// Single-quote a string for POSIX shells. Embedded single quotes become
    /// `'\''` (close quote, escaped quote, reopen quote). Always quotes, even
    /// when not strictly needed, so the result is predictable.
    ///
    /// - Important: fish treats `\'` and `\\` as escapes inside single quotes,
    ///   so this is only safe for strings that pass `isSafeToType`. Callers
    ///   that type a path must check that first.
    static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether text may be inserted into a terminal. Per the Slimer security
    /// rules, text is rejected (never stripped) when it contains control
    /// characters (Unicode Cc: C0, DEL, C1), format characters (Unicode Cf:
    /// bidi embeddings/overrides/isolates, LRM/RLM/ALM, zero-width characters,
    /// BOM, soft hyphen, tag characters, ...), or U+2028/U+2029. Plain spaces
    /// and any other printable Unicode are fine.
    static func isSafeToInsert(_ text: String) -> Bool {
        SlimerUnsafeText.isSafe(text)
    }

    /// Whether a path may be typed into a shell inside single quotes. On top
    /// of `isSafeToInsert`, rejects `'` and `\`, which some shells (fish)
    /// interpret inside single quotes. Paths that fail this are opened via
    /// `working_directory` instead, which never goes through a shell.
    static func isSafeToType(path: String) -> Bool {
        isSafeToInsert(path) && !path.contains("'") && !path.contains("\\")
    }

    /// The `cd` command for an (already expanded) path. Callers must have
    /// checked `isSafeToType(path:)`.
    static func cdCommand(to expandedPath: String) -> String {
        "cd " + quote(expandedPath)
    }

    /// Build a Ghostty `text:` binding action that types `text` into the
    /// terminal. The `text:` payload is parsed with Zig string-literal
    /// escapes, so backslashes in `text` are doubled.
    ///
    /// Nothing is ever sent to clear the shell's input line: line-kill keys
    /// differ between shells and keymaps, and leftover text would be run.
    /// Enter (`\r`) is appended only when `pressEnter` is set, which callers do
    /// only after `SurfaceView.slimerIdlePrompt` returned true.
    ///
    /// Callers must have checked `isSafeToInsert` on `text` first.
    static func textBindingAction(_ text: String, pressEnter: Bool) -> String {
        var payload = text.replacingOccurrences(of: "\\", with: "\\\\")
        if pressEnter { payload += "\\r" }
        return "text:" + payload
    }
}

/// Display strings shared by the palette and the menu.
enum WorkspaceDisplay {
    /// Maximum length of command text shown inside a title.
    static let titleCommandLimit = 60

    /// Suffix marking commands that run without the user pressing Enter.
    static let autoRunMarker = "⏎"

    /// A command's title. When the command text does not start with the name,
    /// the (truncated) command is shown too so a friendly name cannot hide
    /// what will be typed: `name — command`. Auto-run commands get `⏎`.
    static func commandTitle(_ command: WorkspaceCommand) -> String {
        var title = command.name
        let name = command.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || !command.command.lowercased().hasPrefix(name.lowercased()) {
            title += " — " + truncate(command.command, to: titleCommandLimit)
        }
        if !command.confirm {
            title += " " + autoRunMarker
        }
        return title
    }

    /// A location's title: its name, plus `⏎` when its startup command runs
    /// without confirmation.
    static func locationTitle(_ location: WorkspaceLocation) -> String {
        if location.hasStartupCommand && !location.startupConfirm {
            return location.name + " " + autoRunMarker
        }
        return location.name
    }

    /// The path, plus the startup command when there is one.
    static func locationDetail(_ location: WorkspaceLocation) -> String {
        var detail = WorkspacePath.abbreviate(location.expandedPath)
        if let startup = location.trimmedStartupCommand {
            detail += "  → " + truncate(startup, to: titleCommandLimit)
            if !location.startupConfirm { detail += " " + autoRunMarker }
        }
        return detail
    }

    static func truncate(_ string: String, to limit: Int) -> String {
        guard string.count > limit else { return string }
        return String(string.prefix(max(0, limit - 1))) + "…"
    }
}
