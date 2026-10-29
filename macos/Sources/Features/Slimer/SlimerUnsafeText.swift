import Foundation
import GhosttyKit

/// The one definition of "text that must never be typed into a terminal".
///
/// Per `docs/slimer/CONVENTIONS.md`, such text is rejected, never stripped.
/// Shared by `GitShellQuoting`, `SlimerTerminalInput` and `WorkspaceShell`.
enum SlimerUnsafeText {
    /// True when `text` contains no unsafe scalar.
    static func isSafe(_ text: String) -> Bool {
        !text.unicodeScalars.contains(where: isUnsafe)
    }

    /// Rejected scalars: Unicode Cc (C0, DEL, C1), Cf (bidi embeddings,
    /// overrides and isolates, LRM/RLM/ALM, zero-width characters, BOM, soft
    /// hyphen, tag characters, ...), Zl (U+2028) and Zp (U+2029). The bidi
    /// controls are also listed explicitly so they stay rejected regardless of
    /// the Unicode tables in use.
    static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F:
            return true
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        case 0x2028, 0x2029:
            return true
        default:
            break
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return true
        default:
            return false
        }
    }

    /// `text` with every unsafe scalar replaced by U+FFFD, for display only
    /// (chip labels, headers). Never use the result as input.
    static func sanitizedForDisplay(_ text: String) -> String {
        guard !isSafe(text) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(isUnsafe(scalar) ? "\u{FFFD}" : scalar)
        }
        return String(scalars)
    }
}

extension Ghostty.SurfaceView {
    /// True only when the shell sits at an empty primary prompt (OSC 133 shell
    /// integration required), the child is alive and the surface is not
    /// read-only. The only signal Slimer UI uses to decide it may press Enter.
    /// See `ghostty_surface_slimer_idle_prompt` / `src/slimer/prompt.zig`.
    /// Main thread only (like `needsConfirmQuit`).
    var slimerIdlePrompt: Bool {
        guard let surface else { return false }
        return ghostty_surface_slimer_idle_prompt(surface)
    }
}
