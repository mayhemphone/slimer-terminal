import AppKit

/// A parsed Ghostty-style shortcut string such as `cmd+shift+1` or
/// `ctrl+alt+enter`, usable as an `NSMenuItem` key equivalent.
struct WorkspaceShortcut: Equatable {
    /// The key equivalent string for `NSMenuItem.keyEquivalent`.
    let keyEquivalent: String
    /// The modifier mask for `NSMenuItem.keyEquivalentModifierMask`.
    let modifiers: NSEvent.ModifierFlags
    /// Human readable symbols (for the command palette), e.g. `["⌘", "⇧", "1"]`.
    let symbols: [String]

    /// Parse a shortcut. Returns nil for anything that cannot be represented as
    /// a menu key equivalent (unknown key names, multiple keys, no key).
    init?(parsing string: String) {
        let parts = string
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var mods: NSEvent.ModifierFlags = []
        var key: (equivalent: String, symbol: String)?
        for part in parts {
            switch part {
            case "cmd", "command", "super":
                mods.insert(.command)
            case "shift":
                mods.insert(.shift)
            case "ctrl", "control":
                mods.insert(.control)
            case "alt", "opt", "option":
                mods.insert(.option)
            default:
                guard key == nil, let parsed = Self.key(named: part) else { return nil }
                key = parsed
            }
        }
        guard let key else { return nil }

        var symbols: [String] = []
        if mods.contains(.control) { symbols.append("⌃") }
        if mods.contains(.option) { symbols.append("⌥") }
        if mods.contains(.shift) { symbols.append("⇧") }
        if mods.contains(.command) { symbols.append("⌘") }
        symbols.append(key.symbol)

        self.keyEquivalent = key.equivalent
        self.modifiers = mods
        self.symbols = symbols
    }

    private static func functionKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(code)!))
    }

    private static func key(named name: String) -> (equivalent: String, symbol: String)? {
        switch name {
        case "enter", "return": return ("\r", "⏎")
        case "tab": return ("\t", "⇥")
        case "space": return (" ", "␣")
        case "escape", "esc": return ("\u{1B}", "⎋")
        case "backspace": return ("\u{8}", "⌫")
        case "delete": return (functionKey(NSDeleteFunctionKey), "⌦")
        case "up", "arrow_up": return (functionKey(NSUpArrowFunctionKey), "▲")
        case "down", "arrow_down": return (functionKey(NSDownArrowFunctionKey), "▼")
        case "left", "arrow_left": return (functionKey(NSLeftArrowFunctionKey), "◀")
        case "right", "arrow_right": return (functionKey(NSRightArrowFunctionKey), "▶")
        case "home": return (functionKey(NSHomeFunctionKey), "⤒")
        case "end": return (functionKey(NSEndFunctionKey), "⤓")
        case "page_up", "pageup": return (functionKey(NSPageUpFunctionKey), "↑")
        case "page_down", "pagedown": return (functionKey(NSPageDownFunctionKey), "↓")
        case "zero", "digit_0": return ("0", "0")
        case "one", "digit_1": return ("1", "1")
        case "two", "digit_2": return ("2", "2")
        case "three", "digit_3": return ("3", "3")
        case "four", "digit_4": return ("4", "4")
        case "five", "digit_5": return ("5", "5")
        case "six", "digit_6": return ("6", "6")
        case "seven", "digit_7": return ("7", "7")
        case "eight", "digit_8": return ("8", "8")
        case "nine", "digit_9": return ("9", "9")
        case "comma": return (",", ",")
        case "period": return (".", ".")
        case "slash": return ("/", "/")
        case "backslash": return ("\\", "\\")
        case "semicolon": return (";", ";")
        case "apostrophe", "quote": return ("'", "'")
        case "minus": return ("-", "-")
        case "equal", "equals": return ("=", "=")
        case "grave_accent", "backquote", "grave": return ("`", "`")
        case "bracket_left": return ("[", "[")
        case "bracket_right": return ("]", "]")
        default:
            break
        }

        // f1...f20
        if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...20).contains(n) {
            return (functionKey(NSF1FunctionKey + (n - 1)), "F\(n)")
        }

        // Any single printable character.
        if name.count == 1, let ch = name.first, !ch.isWhitespace, !ch.isNewline {
            let s = String(ch)
            return (s, s.uppercased())
        }

        return nil
    }
}
