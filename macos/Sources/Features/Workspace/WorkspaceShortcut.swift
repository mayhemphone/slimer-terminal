import AppKit
import GhosttyKit

/// A parsed Ghostty-style shortcut string such as `cmd+shift+1` or
/// `cmd+alt+enter`, usable as an `NSMenuItem` key equivalent.
struct WorkspaceShortcut: Equatable {
    /// The key equivalent string for `NSMenuItem.keyEquivalent`.
    let keyEquivalent: String
    /// The modifier mask for `NSMenuItem.keyEquivalentModifierMask`.
    let modifiers: NSEvent.ModifierFlags
    /// Human readable symbols (for the command palette), e.g. `["⇧", "⌘", "1"]`.
    let symbols: [String]
    /// The physical Ghostty key (`Ghostty.Input.Key` raw value), used to ask
    /// libghostty whether the combination is already a keybinding.
    let ghosttyKey: String?
    /// The unshifted codepoint for printable keys (0 otherwise).
    let unshiftedCodepoint: UInt32

    /// Whether the shortcut includes ⌘. Workspace shortcuts must, so they can
    /// never take a key a terminal program expects (ctrl/alt combos, plain keys).
    var hasCommand: Bool { modifiers.contains(.command) }

    /// Parse a shortcut. Returns nil for anything that cannot be represented as
    /// a menu key equivalent (unknown key names, multiple keys, no key).
    init?(parsing string: String) {
        let parts = string
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var mods: NSEvent.ModifierFlags = []
        var key: KeyInfo?
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

        self.init(key: key, modifiers: mods)
    }

    private init(key: KeyInfo, modifiers mods: NSEvent.ModifierFlags) {
        var symbols: [String] = []
        if mods.contains(.control) { symbols.append("⌃") }
        if mods.contains(.option) { symbols.append("⌥") }
        if mods.contains(.shift) { symbols.append("⇧") }
        if mods.contains(.command) { symbols.append("⌘") }
        symbols.append(key.symbol)

        self.keyEquivalent = key.equivalent
        self.modifiers = mods
        self.symbols = symbols
        self.ghosttyKey = key.ghosttyKey
        // Printable ASCII keys carry their codepoint so Unicode-trigger
        // bindings (e.g. `cmd+t`) match too; special keys use physical only.
        if let scalar = key.equivalent.unicodeScalars.first,
           key.equivalent.unicodeScalars.count == 1,
           (0x21...0x7E).contains(scalar.value) {
            self.unshiftedCodepoint = scalar.value
        } else {
            self.unshiftedCodepoint = 0
        }
        self.keyInfo = key
    }

    /// The same key with different modifiers (used for ⌥ alternates).
    func with(modifiers: NSEvent.ModifierFlags) -> WorkspaceShortcut {
        WorkspaceShortcut(key: keyInfo, modifiers: modifiers)
    }

    private let keyInfo: KeyInfo

    static func == (lhs: WorkspaceShortcut, rhs: WorkspaceShortcut) -> Bool {
        lhs.keyEquivalent == rhs.keyEquivalent && lhs.modifiers == rhs.modifiers
    }

    // MARK: Policy

    /// Parse `string` and apply the Workspace shortcut policy: the shortcut
    /// must contain ⌘ and must not already be a Ghostty keybinding (`isBound`).
    /// Rejected shortcuts are logged (when `log` is true) and nil is returned.
    static func accepted(
        _ string: String?,
        log: Bool = true,
        isBound: (WorkspaceShortcut) -> Bool
    ) -> WorkspaceShortcut? {
        guard let string, !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let shortcut = WorkspaceShortcut(parsing: string) else {
            if log { WorkspaceStore.logger.warning("ignoring unparseable workspace shortcut \"\(string, privacy: .public)\"") }
            return nil
        }
        guard shortcut.hasCommand else {
            if log { WorkspaceStore.logger.warning("ignoring workspace shortcut \"\(string, privacy: .public)\": must include cmd") }
            return nil
        }
        if isBound(shortcut) {
            if log { WorkspaceStore.logger.warning("ignoring workspace shortcut \"\(string, privacy: .public)\": already a Ghostty keybinding") }
            return nil
        }
        return shortcut
    }

    /// Ask libghostty whether `shortcut` is bound on `surface`. Returns false
    /// when the key has no physical mapping (it cannot collide then). Main
    /// thread only (calls the C API directly because the Swift wrapper is
    /// `@MainActor` and our callers are not actor-annotated).
    static func isGhosttyBinding(_ shortcut: WorkspaceShortcut, on surface: Ghostty.Surface) -> Bool {
        guard let raw = shortcut.ghosttyKey, let key = Ghostty.Input.Key(rawValue: raw) else { return false }
        var mods: Ghostty.Input.Mods = []
        if shortcut.modifiers.contains(.shift) { mods.insert(.shift) }
        if shortcut.modifiers.contains(.control) { mods.insert(.ctrl) }
        if shortcut.modifiers.contains(.option) { mods.insert(.alt) }
        if shortcut.modifiers.contains(.command) { mods.insert(.super) }
        let event = Ghostty.Input.KeyEvent(
            key: key,
            action: .press,
            mods: mods,
            unshiftedCodepoint: shortcut.unshiftedCodepoint
        )
        var flags = ghostty_binding_flags_e(0)
        return event.withCValue { ghostty_surface_key_is_binding(surface.unsafeCValue, $0, &flags) }
    }

    // MARK: Key table

    private struct KeyInfo {
        let equivalent: String
        let symbol: String
        let ghosttyKey: String?
    }

    private static func functionKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(code)!))
    }

    private static let digitNames = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    private static let punctuation: [String: (String, String)] = [
        // name: (character, ghostty key)
        "comma": (",", "comma"), "period": (".", "period"), "slash": ("/", "slash"),
        "backslash": ("\\", "backslash"), "semicolon": (";", "semicolon"),
        "apostrophe": ("'", "quote"), "quote": ("'", "quote"), "minus": ("-", "minus"),
        "equal": ("=", "equal"), "equals": ("=", "equal"),
        "grave_accent": ("`", "backquote"), "backquote": ("`", "backquote"), "grave": ("`", "backquote"),
        "bracket_left": ("[", "bracketLeft"), "bracket_right": ("]", "bracketRight"),
    ]

    private static func key(named name: String) -> KeyInfo? {
        switch name {
        case "enter", "return": return KeyInfo(equivalent: "\r", symbol: "⏎", ghosttyKey: "enter")
        case "tab": return KeyInfo(equivalent: "\t", symbol: "⇥", ghosttyKey: "tab")
        case "space": return KeyInfo(equivalent: " ", symbol: "␣", ghosttyKey: "space")
        case "escape", "esc": return KeyInfo(equivalent: "\u{1B}", symbol: "⎋", ghosttyKey: "escape")
        case "backspace": return KeyInfo(equivalent: "\u{8}", symbol: "⌫", ghosttyKey: "backspace")
        case "delete": return KeyInfo(equivalent: functionKey(NSDeleteFunctionKey), symbol: "⌦", ghosttyKey: "delete")
        case "up", "arrow_up": return KeyInfo(equivalent: functionKey(NSUpArrowFunctionKey), symbol: "▲", ghosttyKey: "arrowUp")
        case "down", "arrow_down":
            return KeyInfo(equivalent: functionKey(NSDownArrowFunctionKey), symbol: "▼", ghosttyKey: "arrowDown")
        case "left", "arrow_left":
            return KeyInfo(equivalent: functionKey(NSLeftArrowFunctionKey), symbol: "◀", ghosttyKey: "arrowLeft")
        case "right", "arrow_right":
            return KeyInfo(equivalent: functionKey(NSRightArrowFunctionKey), symbol: "▶", ghosttyKey: "arrowRight")
        case "home": return KeyInfo(equivalent: functionKey(NSHomeFunctionKey), symbol: "⤒", ghosttyKey: "home")
        case "end": return KeyInfo(equivalent: functionKey(NSEndFunctionKey), symbol: "⤓", ghosttyKey: "end")
        case "page_up", "pageup": return KeyInfo(equivalent: functionKey(NSPageUpFunctionKey), symbol: "↑", ghosttyKey: "pageUp")
        case "page_down", "pagedown":
            return KeyInfo(equivalent: functionKey(NSPageDownFunctionKey), symbol: "↓", ghosttyKey: "pageDown")
        default:
            break
        }

        if let idx = digitNames.firstIndex(of: name) {
            return KeyInfo(equivalent: "\(idx)", symbol: "\(idx)", ghosttyKey: "digit\(idx)")
        }
        if name.hasPrefix("digit_"), let n = Int(name.dropFirst(6)), (0...9).contains(n) {
            return KeyInfo(equivalent: "\(n)", symbol: "\(n)", ghosttyKey: "digit\(n)")
        }
        if let (ch, gk) = punctuation[name] {
            return KeyInfo(equivalent: ch, symbol: ch, ghosttyKey: gk)
        }

        // f1...f20
        if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...20).contains(n) {
            return KeyInfo(equivalent: functionKey(NSF1FunctionKey + (n - 1)), symbol: "F\(n)", ghosttyKey: "f\(n)")
        }

        // Any single printable character.
        if name.count == 1, let ch = name.first, !ch.isWhitespace, !ch.isNewline {
            let s = String(ch)
            let ghosttyKey: String?
            if ch.isASCII && ch.isLetter {
                ghosttyKey = s
            } else if ch.isASCII && ch.isNumber {
                ghosttyKey = "digit\(s)"
            } else {
                ghosttyKey = punctuation.values.first { $0.0 == s }?.1
            }
            return KeyInfo(equivalent: s, symbol: s.uppercased(), ghosttyKey: ghosttyKey)
        }

        return nil
    }
}
