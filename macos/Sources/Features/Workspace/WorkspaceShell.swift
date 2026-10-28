import Foundation

/// Shell text helpers for the Workspace feature. Everything that ends up in a
/// terminal goes through here so quoting and safety checks live in one place.
enum WorkspaceShell {
    /// Single-quote a string for POSIX shells. Embedded single quotes become
    /// `'\''` (close quote, escaped quote, reopen quote). Always quotes, even
    /// when not strictly needed, so the result is predictable.
    static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether text may be inserted into a terminal. Per the Slimer security
    /// rules, text is rejected (never stripped) when it contains C0/C1 control
    /// characters, DEL, U+2028/U+2029, or bidi embedding/override/isolate
    /// controls. Plain spaces and any printable Unicode are fine.
    static func isSafeToInsert(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || v == 0x7F { return false } // C0 + DEL
            if (0x80...0x9F).contains(v) { return false } // C1
            if v == 0x2028 || v == 0x2029 { return false } // line/paragraph separator
            if (0x202A...0x202E).contains(v) { return false } // bidi embeddings/overrides
            if (0x2066...0x2069).contains(v) { return false } // bidi isolates
        }
        return true
    }

    /// The `cd` command for an (already expanded) path.
    static func cdCommand(to expandedPath: String) -> String {
        "cd " + quote(expandedPath)
    }

    /// Build a Ghostty `text:` binding action that types `text` into the
    /// terminal, optionally followed by Enter (`\r`). The `text:` payload is
    /// parsed with Zig string-literal escapes, so backslashes are doubled.
    /// Callers must have checked `isSafeToInsert` first.
    static func textBindingAction(_ text: String, pressEnter: Bool) -> String {
        var payload = text.replacingOccurrences(of: "\\", with: "\\\\")
        if pressEnter { payload += "\\r" }
        return "text:" + payload
    }
}
