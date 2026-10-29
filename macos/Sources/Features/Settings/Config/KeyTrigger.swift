import AppKit
import Carbon.HIToolbox

/// Ghostty keybind triggers produced by the Settings key recorder.
///
/// The recorder is the only way Settings creates a trigger, and the only output it can
/// produce is `<modifiers>+<key>` where modifiers are a subset of `cmd`, `ctrl`, `alt`,
/// `shift` (in that order) and the key is one name from ``allowedKeys``. ``isValid(_:)``
/// accepts exactly that grammar, so nothing else can reach the config file.
enum KeyTrigger {
    static let modifierOrder = ["cmd", "ctrl", "alt", "shift"]

    /// Named keys (Ghostty's physical key names) plus single letters and digits.
    static let namedKeys: Set<String> = Set([
        "backquote", "backslash", "bracket_left", "bracket_right", "comma", "equal", "minus",
        "period", "quote", "semicolon", "slash",
        "enter", "tab", "space", "escape", "backspace", "delete",
        "home", "end", "page_up", "page_down",
        "arrow_up", "arrow_down", "arrow_left", "arrow_right",
    ]).union((1...20).map { "f\($0)" })

    static func isAllowedKey(_ key: String) -> Bool {
        if namedKeys.contains(key) { return true }
        guard key.count == 1, let scalar = key.unicodeScalars.first else { return false }
        switch scalar {
        case "a"..."z", "0"..."9": return true
        default: return false
        }
    }

    // MARK: - Recording

    /// Maps a key press to a trigger string. Returns nil for modifier-only presses and keys
    /// that have no stable Ghostty name (keypad, media keys, non-ASCII characters).
    ///
    /// - Parameters:
    ///   - keyCode: the virtual key code (`NSEvent.keyCode`).
    ///   - characters: the characters the key produces with no modifiers
    ///     (`event.characters(byApplyingModifiers: [])`). Used for letters, so the trigger
    ///     follows the keyboard layout like Ghostty's own single-letter triggers.
    ///   - modifiers: device-independent modifier flags.
    static func trigger(keyCode: Int, characters: String?, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let key = keyName(keyCode: keyCode, characters: characters) else { return nil }
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    static func keyName(keyCode: Int, characters: String?) -> String? {
        if let name = specialKeys[keyCode] { return name }
        // Letters: prefer what the layout produces (AZERTY's A key is "a").
        if letterKeyCodes[keyCode] != nil {
            if let chars = characters?.lowercased(), chars.count == 1,
               let scalar = chars.unicodeScalars.first, ("a"..."z").contains(scalar) {
                return chars
            }
            return letterKeyCodes[keyCode]
        }
        return nil
    }

    private static let letterKeyCodes: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
        kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
        kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
        kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
        kVK_ANSI_Z: "z",
    ]

    /// Physical keys whose name doesn't depend on the layout.
    private static let specialKeys: [Int: String] = [
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Grave: "backquote", kVK_ANSI_Backslash: "backslash",
        kVK_ANSI_LeftBracket: "bracket_left", kVK_ANSI_RightBracket: "bracket_right",
        kVK_ANSI_Comma: "comma", kVK_ANSI_Equal: "equal", kVK_ANSI_Minus: "minus",
        kVK_ANSI_Period: "period", kVK_ANSI_Quote: "quote", kVK_ANSI_Semicolon: "semicolon",
        kVK_ANSI_Slash: "slash",
        kVK_Return: "enter", kVK_Tab: "tab", kVK_Space: "space", kVK_Escape: "escape",
        kVK_Delete: "backspace", kVK_ForwardDelete: "delete",
        kVK_Home: "home", kVK_End: "end", kVK_PageUp: "page_up", kVK_PageDown: "page_down",
        kVK_UpArrow: "arrow_up", kVK_DownArrow: "arrow_down",
        kVK_LeftArrow: "arrow_left", kVK_RightArrow: "arrow_right",
        kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4", kVK_F5: "f5",
        kVK_F6: "f6", kVK_F7: "f7", kVK_F8: "f8", kVK_F9: "f9", kVK_F10: "f10",
        kVK_F11: "f11", kVK_F12: "f12", kVK_F13: "f13", kVK_F14: "f14", kVK_F15: "f15",
        kVK_F16: "f16", kVK_F17: "f17", kVK_F18: "f18", kVK_F19: "f19", kVK_F20: "f20",
    ]

    // MARK: - Validation

    /// Whether `trigger` is exactly in the recorder's grammar: canonical modifier names in
    /// canonical order, each at most once, then one allowed key.
    static func isValid(_ trigger: String, requireModifier: Bool = false) -> Bool {
        let parts = trigger.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, isAllowedKey(key) else { return false }
        let mods = parts.dropLast()
        var lastIndex = -1
        for mod in mods {
            guard let idx = modifierOrder.firstIndex(of: mod), idx > lastIndex else { return false }
            lastIndex = idx
        }
        if requireModifier && mods.isEmpty {
            // Function keys are fine on their own; anything else would steal a typing key.
            return key.hasPrefix("f") && key.count > 1 && Int(key.dropFirst()) != nil
        }
        return true
    }

    /// Whether `trigger` is usable as a Workspace shortcut (see `WorkspaceShortcut`): it
    /// must contain `cmd` and parse with the Workspace parser.
    static func isValidWorkspaceShortcut(_ trigger: String) -> Bool {
        guard isValid(trigger), trigger.split(separator: "+").contains("cmd") else { return false }
        return WorkspaceShortcut(parsing: trigger) != nil
    }

    // MARK: - Display

    /// `cmd+shift+backquote` → `⇧⌘``.
    static func displayString(_ trigger: String) -> String {
        let parts = trigger.split(separator: "+").map(String.init)
        guard let key = parts.last else { return trigger }
        var out = ""
        if parts.contains("ctrl") { out += "⌃" }
        if parts.contains("alt") { out += "⌥" }
        if parts.contains("shift") { out += "⇧" }
        if parts.contains("cmd") { out += "⌘" }
        return out + (keySymbols[key] ?? key.uppercased())
    }

    private static let keySymbols: [String: String] = [
        "backquote": "`", "backslash": "\\", "bracket_left": "[", "bracket_right": "]",
        "comma": ",", "equal": "=", "minus": "-", "period": ".", "quote": "'",
        "semicolon": ";", "slash": "/", "enter": "↩", "tab": "⇥", "space": "Space",
        "escape": "⎋", "backspace": "⌫", "delete": "⌦", "home": "↖", "end": "↘",
        "page_up": "⇞", "page_down": "⇟", "arrow_up": "↑", "arrow_down": "↓",
        "arrow_left": "←", "arrow_right": "→",
    ]
}

// MARK: - Global keybinds

/// The global keybinds the General pane manages.
enum ManagedGlobalAction: String, CaseIterable, Identifiable {
    case toggleQuickTerminal = "toggle_quick_terminal"
    case newWindow = "new_window"
    case toggleCommandPalette = "toggle_command_palette"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleQuickTerminal: return "Toggle drawer"
        case .newWindow: return "New window"
        case .toggleCommandPalette: return "Command palette"
        }
    }

    /// `global:<trigger>=<action>`, or nil when the trigger isn't valid.
    func keybindValue(trigger: String) -> String? {
        guard KeyTrigger.isValid(trigger, requireModifier: true) else { return nil }
        return "global:\(trigger)=\(rawValue)"
    }
}
