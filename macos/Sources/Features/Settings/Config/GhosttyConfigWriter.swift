import Foundation

/// Pure text transforms for the Slimer-managed block in the user's Ghostty config file.
///
/// Settings never edits a user's own lines. Every Ghostty key it manages is written inside
/// one fenced block:
///
/// ```
/// # >>> slimer managed (edit in Settings) >>>
/// quick-terminal-position = right
/// keybind = global:cmd+backquote=toggle_quick_terminal
/// # <<< slimer managed <<<
/// ```
///
/// The block is replaced in place when present, otherwise appended at the end of the file
/// after a blank line. Because later lines win in a Ghostty config, ``analyze(text:keys:)``
/// reports user lines *after* the block that would override it, so the UI can warn instead
/// of editing them.
///
/// Everything here is pure (no I/O) so it can be unit tested exhaustively.
enum GhosttyConfigWriter {
    static let beginMarker = "# >>> slimer managed (edit in Settings) >>>"
    static let endMarker = "# <<< slimer managed <<<"

    /// One managed key and its values, in file order. Repeatable keys (`keybind`,
    /// `font-family`) carry several values; every other key carries exactly one.
    struct Entry: Equatable {
        var key: String
        var values: [String]

        init(_ key: String, _ values: [String]) {
            self.key = key
            self.values = values
        }
    }

    enum WriteError: Error, Equatable, CustomStringConvertible {
        /// The key is not a plain Ghostty key name (`[a-z0-9-]+`).
        case invalidKey(String)
        /// The value is empty, padded with whitespace, or contains a newline or control
        /// character.
        case invalidValue(key: String, value: String)
        /// A begin marker without an end marker (or vice versa), or more than one block.
        /// The file is never written in this state.
        case malformedBlock(String)

        var description: String {
            switch self {
            case .invalidKey(let key):
                return "“\(key)” is not a valid config key."
            case .invalidValue(let key, let value):
                return "Refusing to write \(key) = “\(value.debugDescription)”: values must be one non-empty line without control characters."
            case .malformedBlock(let reason):
                return "The Slimer block in your config is damaged (\(reason)). Fix it by hand; Settings won't write until then."
            }
        }
    }

    // MARK: - Lines

    /// A parsed `key = value` line. Comments and blank lines are not settings.
    struct Setting: Equatable {
        /// 1-based line number in the file.
        var line: Int
        var key: String
        var value: String
    }

    /// The text split into lines without their terminators, plus the terminator style.
    struct Lines {
        var lines: [String]
        /// `"\r\n"` when the file uses CRLF line endings, otherwise `"\n"`.
        var newline: String
        /// Whether the original text ended with a line terminator.
        var hasTrailingNewline: Bool
    }

    static func split(_ text: String) -> Lines {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        guard !text.isEmpty else { return Lines(lines: [], newline: "\n", hasTrailingNewline: false) }
        var parts = text.components(separatedBy: "\n")
        let trailing = parts.last == ""
        if trailing { parts.removeLast() }
        // Strip a CR that belongs to a CRLF terminator. A lone CR elsewhere stays put.
        let lines = parts.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        return Lines(lines: lines, newline: newline, hasTrailingNewline: trailing)
    }

    /// Parses one config line the way Ghostty does: `key = value`, `#` comments only at the
    /// start of a line, optional surrounding quotes around the value.
    static func parseSetting(_ raw: String, line: Int) -> Setting? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        var value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return Setting(line: line, key: key, value: value)
    }

    /// The managed block's position (0-based, inclusive line indices), or nil if absent.
    static func blockRange(in lines: [String]) throws -> ClosedRange<Int>? {
        let normalized = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        let begins = normalized.indices.filter { normalized[$0] == beginMarker }
        let ends = normalized.indices.filter { normalized[$0] == endMarker }
        switch (begins.count, ends.count) {
        case (0, 0):
            return nil
        case (1, 1):
            guard begins[0] < ends[0] else {
                throw WriteError.malformedBlock("the end marker comes before the begin marker")
            }
            return begins[0]...ends[0]
        case (0, _):
            throw WriteError.malformedBlock("end marker without a begin marker")
        case (_, 0):
            throw WriteError.malformedBlock("begin marker without an end marker")
        default:
            throw WriteError.malformedBlock("more than one Slimer block")
        }
    }

    // MARK: - Reading the block

    /// The entries currently inside the managed block, in order. Keys keep first-seen order.
    static func managedEntries(in text: String) throws -> [Entry] {
        let parsed = split(text)
        guard let range = try blockRange(in: parsed.lines) else { return [] }
        var entries: [Entry] = []
        for idx in range.lowerBound + 1 ..< range.upperBound {
            guard let setting = parseSetting(parsed.lines[idx], line: idx + 1) else { continue }
            if let existing = entries.firstIndex(where: { $0.key == setting.key }) {
                entries[existing].values.append(setting.value)
            } else {
                entries.append(Entry(setting.key, [setting.value]))
            }
        }
        return entries
    }

    /// Every `key = value` line outside the managed block, in file order.
    static func userSettings(in text: String) throws -> (before: [Setting], after: [Setting], hasBlock: Bool) {
        let parsed = split(text)
        let range = try blockRange(in: parsed.lines)
        var before: [Setting] = []
        var after: [Setting] = []
        for (idx, raw) in parsed.lines.enumerated() {
            if let range, range.contains(idx) { continue }
            guard let setting = parseSetting(raw, line: idx + 1) else { continue }
            if let range, idx > range.upperBound {
                after.append(setting)
            } else {
                before.append(setting)
            }
        }
        return (before, after, range != nil)
    }

    // MARK: - Writing

    /// Returns `text` with the managed block replaced by `entries` (or appended when the file
    /// has no block). Lines outside the block are never changed. With no entries (or only
    /// empty ones) an existing block is removed and nothing is appended.
    static func render(text: String, entries: [Entry]) throws -> String {
        for entry in entries {
            guard isValidKey(entry.key) else { throw WriteError.invalidKey(entry.key) }
            for value in entry.values where !isValidValue(value) {
                throw WriteError.invalidValue(key: entry.key, value: value)
            }
        }

        let parsed = split(text)
        let range = try blockRange(in: parsed.lines)
        let body = entries.flatMap { entry in entry.values.map { "\(entry.key) = \($0)" } }
        let block = body.isEmpty ? [] : [beginMarker] + body + [endMarker]

        var lines = parsed.lines
        var trailingNewline = parsed.hasTrailingNewline
        if let range {
            lines.replaceSubrange(range, with: block)
        } else if !block.isEmpty {
            if !lines.isEmpty {
                // An existing last line without a terminator gets one; a blank line
                // separates the block from the user's settings.
                if lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
                    lines.append("")
                }
            }
            lines += block
            trailingNewline = true
        }

        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: parsed.newline) + (trailingNewline ? parsed.newline : "")
    }

    /// Ghostty key names: lowercase ASCII letters, digits and dashes.
    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "0"..."9", "-": return true
            default: return false
            }
        }
    }

    /// One non-empty line with no control characters (C0, DEL, C1), no Unicode line or
    /// paragraph separators, and no leading/trailing whitespace.
    static func isValidValue(_ value: String) -> Bool {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespaces) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x00...0x1F, 0x7F, 0x80...0x9F, 0x2028, 0x2029: return false
            default: return true
            }
        }
    }

    // MARK: - Analysis

    /// How a later line for the same key combines with an earlier one.
    enum KeySemantics {
        /// The later line replaces the earlier value.
        case lastWins
        /// The later line appends (e.g. a `font-family` fallback).
        case appends
        /// `keybind`: a later line for the same trigger (or `clear`) overrides.
        case keybind
    }

    static func semantics(for key: String) -> KeySemantics {
        switch key {
        case "keybind": return .keybind
        case "font-family", "font-family-bold", "font-family-italic", "font-family-bold-italic":
            return .appends
        default: return .lastWins
        }
    }

    /// Something about the user's own lines the UI should explain.
    struct Finding: Equatable, Identifiable {
        enum Kind: Equatable {
            /// A user line after the block wins over the managed value. Settings can't
            /// change this key until the user edits that line.
            case overriddenAfter
            /// A user line after the block adds to the managed value (fallback font, extra
            /// binding for the same action).
            case addsAfter
            /// A user line before the block; the block wins.
            case setBefore
            /// `config-file` includes load after this file and may override anything.
            case include
        }

        var kind: Kind
        var key: String
        var line: Int
        var value: String

        var id: String { "\(kind)-\(key)-\(line)" }

        var message: String {
            switch kind {
            case .overriddenAfter:
                return "Your config sets \(key) on line \(line) after Slimer's block; Settings can't change it."
            case .addsAfter:
                return "Your config also sets \(key) on line \(line) after Slimer's block; it is added to Slimer's value."
            case .setBefore:
                return "Your config sets \(key) on line \(line); Slimer's block comes later and takes precedence."
            case .include:
                return "Line \(line) includes “\(value)”, which loads after this file and can override any setting."
            }
        }
    }

    /// Findings for `keys` (the keys Settings manages or is about to manage).
    ///
    /// - When the file has no block yet, the block will be appended at the end, so every
    ///   existing user line counts as "before".
    /// - `keybind` lines are matched by the triggers in `managedKeybinds`, and by action
    ///   name for the actions those values bind plus `keybindActions` (so a line binding the
    ///   same action with another trigger is flagged too). `clear` always matches.
    static func analyze(
        text: String,
        keys: Set<String>,
        managedKeybinds: [String] = [],
        keybindActions: Set<String> = []
    ) throws -> [Finding] {
        let settings = try userSettings(in: text)
        var findings: [Finding] = []

        let managedTriggers = Set(managedKeybinds.compactMap { KeybindValue(parsing: $0)?.normalizedTrigger })
        let managedActions = Set(managedKeybinds.compactMap { KeybindValue(parsing: $0)?.actionName })
            .subtracting(["unbind"])
            .union(keybindActions)

        func relevant(_ setting: Setting) -> Bool {
            guard keys.contains(setting.key) else { return false }
            guard setting.key == "keybind" else { return true }
            if setting.value == "clear" { return true }
            guard let bind = KeybindValue(parsing: setting.value) else { return false }
            return managedTriggers.contains(bind.normalizedTrigger) || managedActions.contains(bind.actionName)
        }

        for setting in settings.before where relevant(setting) {
            findings.append(Finding(kind: .setBefore, key: setting.key, line: setting.line, value: setting.value))
        }

        for setting in settings.after where relevant(setting) {
            let kind: Finding.Kind
            switch semantics(for: setting.key) {
            case .lastWins:
                kind = .overriddenAfter
            case .appends:
                // An empty value resets the list, wiping out the managed value.
                kind = setting.value.isEmpty ? .overriddenAfter : .addsAfter
            case .keybind:
                if setting.value == "clear" {
                    kind = .overriddenAfter
                } else if let bind = KeybindValue(parsing: setting.value),
                          managedTriggers.contains(bind.normalizedTrigger) {
                    kind = .overriddenAfter
                } else {
                    kind = .addsAfter
                }
            }
            findings.append(Finding(kind: kind, key: setting.key, line: setting.line, value: setting.value))
        }

        for setting in settings.before + settings.after where setting.key == "config-file" {
            findings.append(Finding(kind: .include, key: setting.key, line: setting.line, value: setting.value))
        }
        return findings.sorted { $0.line < $1.line }
    }
}

// MARK: - Keybind values

/// A `keybind` value split into its prefixes, trigger and action, for analysis only.
/// Nothing parsed here is ever written back unless it passes ``KeyTrigger`` validation.
struct KeybindValue: Equatable {
    /// `global`, `all`, `unconsumed`, `performable` prefixes, in order.
    var prefixes: [String]
    /// The trigger as written (e.g. `cmd+backquote`).
    var trigger: String
    /// The full action (e.g. `toggle_quick_terminal`, `goto_tab:1`).
    var action: String

    static let knownPrefixes: Set<String> = ["global", "all", "unconsumed", "performable"]

    init?(parsing raw: String) {
        var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
        var prefixes: [String] = []
        while let colon = rest.firstIndex(of: ":") {
            let candidate = String(rest[..<colon])
            guard Self.knownPrefixes.contains(candidate) else { break }
            prefixes.append(candidate)
            rest = rest[rest.index(after: colon)...]
        }
        // The trigger can itself be `=` (e.g. `cmd+=`), so split on the first `=` that is
        // not the first character of a trigger component.
        var splitIndex: Substring.Index?
        var idx = rest.startIndex
        var componentStart = true
        while idx < rest.endIndex {
            let ch = rest[idx]
            if ch == "=" && !componentStart {
                splitIndex = idx
                break
            }
            componentStart = (ch == "+" || ch == ">")
            idx = rest.index(after: idx)
        }
        guard let splitIndex else { return nil }
        let trigger = rest[..<splitIndex].trimmingCharacters(in: .whitespaces)
        let action = rest[rest.index(after: splitIndex)...].trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !action.isEmpty else { return nil }
        self.prefixes = prefixes
        self.trigger = trigger
        self.action = action
    }

    /// The action name without parameters (`goto_tab:1` → `goto_tab`).
    var actionName: String {
        action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
    }

    /// Lowercased trigger with modifiers canonicalized and sorted, so `shift+cmd+a` and
    /// `command+shift+a` compare equal.
    var normalizedTrigger: String {
        let aliases = ["command": "cmd", "super": "cmd", "control": "ctrl", "opt": "alt", "option": "alt"]
        let modifierOrder = ["cmd", "ctrl", "alt", "shift"]
        var mods: [String] = []
        var keys: [String] = []
        for part in trigger.lowercased().split(separator: "+").map(String.init) {
            let name = aliases[part] ?? part
            if modifierOrder.contains(name) {
                if !mods.contains(name) { mods.append(name) }
            } else {
                keys.append(name)
            }
        }
        mods.sort { (modifierOrder.firstIndex(of: $0) ?? 0) < (modifierOrder.firstIndex(of: $1) ?? 0) }
        return (mods + keys).joined(separator: "+")
    }
}
