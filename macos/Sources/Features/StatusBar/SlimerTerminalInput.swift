import Foundation
import GhosttyKit

/// Inserts command text into a terminal surface the way a `text:` keybind does.
///
/// Per `docs/slimer/CONVENTIONS.md`, UI actions never run commands in a hidden
/// subprocess: the command is typed into the user's shell where they can see it,
/// and Enter is only sent after an explicit click and only when the shell is idle.
enum SlimerTerminalInput {
    enum InputError: Error, Equatable {
        case empty
        /// C0/C1 controls, DEL, U+2028/U+2029 or bidi controls in the command text.
        case containsControlCharacters
    }

    /// What to send around the command text.
    struct Plan: Equatable {
        /// Send Ctrl-U first to clear whatever is typed at the prompt.
        var clearLine: Bool
        /// Send Enter after the command.
        var pressEnter: Bool
    }

    /// Decide how to insert a command.
    ///
    /// - Parameters:
    ///   - runRequested: the user clicked the explicit "Run" button (as opposed
    ///     to "Insert").
    ///   - hasForegroundProcess: the surface is running something other than an
    ///     idle shell prompt (`SurfaceView.needsConfirmQuit`).
    ///
    /// With a foreground process the text is only typed: no Ctrl-U (it would go to
    /// that program) and never Enter. At an idle prompt the line is cleared first,
    /// and Enter is sent only for an explicit run request.
    static func plan(runRequested: Bool, hasForegroundProcess: Bool) -> Plan {
        if hasForegroundProcess {
            return Plan(clearLine: false, pressEnter: false)
        }
        return Plan(clearLine: true, pressEnter: runRequested)
    }

    /// Escape `text` for the parameter of a `text:` binding action.
    ///
    /// Ghostty parses the parameter as a Zig string literal body
    /// (`src/config/string.zig`): a backslash starts an escape sequence and
    /// everything else is copied byte for byte. Doubling backslashes is therefore
    /// the only escaping needed for literal text.
    static func escapeForTextAction(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
    }

    /// The full binding action string for `command` under `plan`, for example
    /// `text:\x15git pull --ff-only\r`. Throws if the command is empty or contains
    /// characters that must never be typed into a terminal (rejected, not stripped).
    static func bindingAction(command: String, plan: Plan) throws -> String {
        try validate(command)
        var action = "text:"
        if plan.clearLine { action += "\\x15" }
        action += escapeForTextAction(command)
        if plan.pressEnter { action += "\\r" }
        return action
    }

    static func validate(_ command: String) throws {
        guard !command.isEmpty else { throw InputError.empty }
        for scalar in command.unicodeScalars where isForbidden(scalar) {
            throw InputError.containsControlCharacters
        }
    }

    /// Type `command` into `surfaceView`. Returns `false` when nothing was sent.
    @MainActor
    @discardableResult
    static func insert(_ command: String, into surfaceView: Ghostty.SurfaceView, run: Bool) -> Bool {
        guard let surface = surfaceView.surface else { return false }
        let plan = plan(runRequested: run, hasForegroundProcess: surfaceView.needsConfirmQuit)
        guard let action = try? bindingAction(command: command, plan: plan) else { return false }
        return ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x80...0x9F:
            return true
        case 0x2028, 0x2029:
            return true
        case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F, 0x061C:
            return true
        default:
            return false
        }
    }
}
