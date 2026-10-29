import Foundation
import GhosttyKit

/// Inserts command text into a terminal surface the way a `text:` keybind does.
///
/// Per `docs/slimer/CONVENTIONS.md`, UI actions never run commands in a hidden
/// subprocess: the command is typed into the user's shell where they can see it.
/// Enter is only sent after an explicit "Run" click and only when the shell sits
/// at an empty primary prompt (`SurfaceView.slimerIdlePrompt`). Nothing is ever
/// sent to clear the user's input line (line-kill keys differ between shells
/// and keymaps; leftover text would be executed).
enum SlimerTerminalInput {
    enum InputError: Error, Equatable {
        case empty
        /// Characters rejected by `SlimerUnsafeText`.
        case containsControlCharacters
        /// The surface is gone or Ghostty rejected the action.
        case surfaceUnavailable
    }

    /// What to do with a requested insertion.
    enum Decision: Equatable {
        /// Type the text, then Enter if `pressEnter`.
        case type(pressEnter: Bool)
        /// The prompt is not idle and empty; typing would mix with whatever is
        /// there. Ask the user before typing (never with Enter).
        case needsConfirmation
        /// Running was requested but the prompt is not idle and empty.
        case refuseRun
    }

    /// Decide how to insert a command.
    ///
    /// - Parameters:
    ///   - runRequested: the user clicked "Run" (as opposed to "Insert").
    ///   - idlePrompt: `SurfaceView.slimerIdlePrompt` at the time of the click.
    ///   - confirmedWhileBusy: the user explicitly chose "Insert Anyway" after
    ///     being told the prompt is not idle and empty.
    static func decide(runRequested: Bool, idlePrompt: Bool, confirmedWhileBusy: Bool) -> Decision {
        if idlePrompt {
            return .type(pressEnter: runRequested)
        }
        if runRequested { return .refuseRun }
        return confirmedWhileBusy ? .type(pressEnter: false) : .needsConfirmation
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

    /// The full binding action string for `command`, for example
    /// `text:git pull --ff-only\r`. Throws if the command is empty or contains
    /// characters that must never be typed into a terminal (rejected, not stripped).
    static func bindingAction(command: String, pressEnter: Bool) throws -> String {
        try validate(command)
        var action = "text:" + escapeForTextAction(command)
        if pressEnter { action += "\\r" }
        return action
    }

    static func validate(_ command: String) throws {
        guard !command.isEmpty else { throw InputError.empty }
        guard SlimerUnsafeText.isSafe(command) else { throw InputError.containsControlCharacters }
    }

    /// Type `command` into `surfaceView` per `decide`. Returns the decision that
    /// was applied; `.type` means the text was sent.
    @MainActor
    static func insert(
        _ command: String,
        into surfaceView: Ghostty.SurfaceView,
        run: Bool,
        confirmedWhileBusy: Bool
    ) -> Result<Decision, InputError> {
        let decision = decide(
            runRequested: run,
            idlePrompt: surfaceView.slimerIdlePrompt,
            confirmedWhileBusy: confirmedWhileBusy
        )
        guard case .type(let pressEnter) = decision else { return .success(decision) }
        let action: String
        do {
            action = try bindingAction(command: command, pressEnter: pressEnter)
        } catch let error as InputError {
            return .failure(error)
        } catch {
            return .failure(.containsControlCharacters)
        }
        guard let surface = surfaceView.surface,
              ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) else {
            return .failure(.surfaceUnavailable)
        }
        return .success(decision)
    }
}
