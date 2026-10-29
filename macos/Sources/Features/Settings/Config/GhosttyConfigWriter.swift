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
/// - The block is updated in place when present, otherwise appended at the end of the file
///   after a blank line.
/// - Inside the block only lines Settings *owns* (see the `owns` parameter) are rewritten;
///   comments, unknown keys (e.g. from a newer Slimer) and hand-added lines stay verbatim and
///   in place.
/// - Each existing line keeps its own terminator (LF, CRLF, or a trailing lone CR) and a
///   UTF-8 BOM is kept. New lines use the file's majority line ending.
/// - Because later lines win in a Ghostty config, ``analyze(lines:keys:managedKeybinds:keybindActions:)``
///   reports user lines *after* the block that override it, so the UI can warn instead of
///   editing them.
///
/// Everything here is pure (no I/O) so it can be unit tested exhaustively.
enum GhosttyConfigWriter {
    static let beginMarker = "# >>> slimer managed (edit in Settings) >>>"
    static let endMarker = "# <<< slimer managed <<<"

    /// Ghostty's config line reader stops at lines longer than this (4096-byte buffer minus
    /// the `--` prefix it adds).
    static let maxLineBytes = 4094

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

    /// Decides whether a line inside the block belongs to Settings (and may be rewritten).
    typealias Ownership = (_ key: String, _ value: String) -> Bool

    /// Owns every line: the whole block is Settings'.
    static let ownsEverything: Ownership = { _, _ in true }

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

    /// One line and the bytes that ended it: `"\n"`, `"\r\n"`, `"\r"` (a lone CR at the very
    /// end of the file) or `""` (last line without a terminator).
    struct Line: Equatable {
        var content: String
        var terminator: String
    }

    /// A file split into lines, keeping everything needed to put it back together exactly.
    struct Lines: Equatable {
        var lines: [Line]
        /// Whether the text started with a UTF-8 byte order mark.
        var hasBOM: Bool
        /// The majority line ending, used for new lines.
        var newline: String

        var contents: [String] { lines.map(\.content) }

        func joined() -> String {
            (hasBOM ? "\u{FEFF}" : "") + lines.map { $0.content + $0.terminator }.joined()
        }
    }

    static func split(_ text: String) -> Lines {
        var body = Substring(text).unicodeScalars
        let hasBOM = body.first == "\u{FEFF}"
        if hasBOM { body = body.dropFirst() }

        var lines: [Line] = []
        var crlf = 0
        var lf = 0
        // Split on LF only (like Ghostty), scalar by scalar: Swift treats "\r\n" as one
        // Character, so Character-based splitting would miss CRLF lines. A CR right before
        // the LF is part of the terminator.
        var current = String.UnicodeScalarView()
        for scalar in body {
            guard scalar == "\n" else {
                current.append(scalar)
                continue
            }
            if current.last == "\r" {
                current.removeLast()
                crlf += 1
                lines.append(Line(content: String(current), terminator: "\r\n"))
            } else {
                lf += 1
                lines.append(Line(content: String(current), terminator: "\n"))
            }
            current = String.UnicodeScalarView()
        }
        if !current.isEmpty {
            if current.last == "\r" {
                current.removeLast()
                lines.append(Line(content: String(current), terminator: "\r"))
            } else {
                lines.append(Line(content: String(current), terminator: ""))
            }
        }
        return Lines(lines: lines, hasBOM: hasBOM, newline: crlf > lf ? "\r\n" : "\n")
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

    /// The owned entries currently inside the managed block, in order. Keys keep first-seen
    /// order.
    static func managedEntries(in text: String, owns: Ownership = ownsEverything) throws -> [Entry] {
        try managedEntries(lines: split(text), owns: owns)
    }

    static func managedEntries(lines parsed: Lines, owns: Ownership = ownsEverything) throws -> [Entry] {
        guard let range = try blockRange(in: parsed.contents) else { return [] }
        var entries: [Entry] = []
        for idx in range.lowerBound + 1 ..< range.upperBound {
            guard let setting = parseSetting(parsed.lines[idx].content, line: idx + 1),
                  owns(setting.key, setting.value) else { continue }
            if let existing = entries.firstIndex(where: { $0.key == setting.key }) {
                entries[existing].values.append(setting.value)
            } else {
                entries.append(Entry(setting.key, [setting.value]))
            }
        }
        return entries
    }

    struct UserSettings: Equatable {
        var before: [Setting]
        var after: [Setting]
        var hasBlock: Bool
    }

    /// Every `key = value` line outside the managed block, in file order.
    static func userSettings(in text: String) throws -> UserSettings {
        try userSettings(lines: split(text))
    }

    static func userSettings(lines parsed: Lines) throws -> UserSettings {
        let range = try blockRange(in: parsed.contents)
        var before: [Setting] = []
        var after: [Setting] = []
        for (idx, line) in parsed.lines.enumerated() {
            if let range, range.contains(idx) { continue }
            guard let setting = parseSetting(line.content, line: idx + 1) else { continue }
            if let range, idx > range.upperBound {
                after.append(setting)
            } else {
                before.append(setting)
            }
        }
        return UserSettings(before: before, after: after, hasBlock: range != nil)
    }

    // MARK: - Writing

    /// Returns `text` with the managed block updated to `entries`.
    ///
    /// - Lines outside the block are never changed.
    /// - Inside the block, lines `owns` claims are replaced: a key's new values go where its
    ///   first owned line was; keys that weren't there are added before the end marker in
    ///   `entries` order. Every other block line stays verbatim and in place.
    /// - With no block yet, one is appended (only if there is something to write). A block
    ///   left with nothing but blank lines is removed.
    static func render(text: String, entries: [Entry], owns: Ownership = ownsEverything) throws -> String {
        try render(lines: split(text), entries: entries, owns: owns)
    }

    static func render(lines parsed: Lines, entries: [Entry], owns: Ownership = ownsEverything) throws -> String {
        for entry in entries {
            guard isValidKey(entry.key) else { throw WriteError.invalidKey(entry.key) }
            for value in entry.values where !isValidValue(value) {
                throw WriteError.invalidValue(key: entry.key, value: value)
            }
        }
        let wanted = entries.filter { !$0.values.isEmpty }
        let nl = parsed.newline
        func newLines(_ entry: Entry) -> [Line] {
            entry.values.map { Line(content: "\(entry.key) = \($0)", terminator: nl) }
        }

        var lines = parsed.lines
        if let range = try blockRange(in: parsed.contents) {
            var inner: [Line] = []
            var placed = Set<String>()
            for idx in range.lowerBound + 1 ..< range.upperBound {
                let line = parsed.lines[idx]
                if let setting = parseSetting(line.content, line: idx + 1), owns(setting.key, setting.value) {
                    if !placed.contains(setting.key), let entry = wanted.first(where: { $0.key == setting.key }) {
                        inner += newLines(entry)
                    }
                    placed.insert(setting.key)
                    continue
                }
                inner.append(line)
            }
            for entry in wanted where !placed.contains(entry.key) {
                inner += newLines(entry)
            }
            let keepsSomething = inner.contains { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
            if keepsSomething {
                var begin = parsed.lines[range.lowerBound]
                if begin.terminator.isEmpty || begin.terminator == "\r" { begin.terminator = nl }
                lines.replaceSubrange(range, with: [begin] + inner + [parsed.lines[range.upperBound]])
            } else {
                lines.removeSubrange(range)
            }
        } else if !wanted.isEmpty {
            if var last = lines.popLast() {
                // The last line needs a terminator before anything can follow it.
                if last.terminator.isEmpty { last.terminator = nl }
                if last.terminator == "\r" { last.terminator = "\r\n" }
                lines.append(last)
                if !last.content.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.append(Line(content: "", terminator: nl))
                }
            }
            lines.append(Line(content: beginMarker, terminator: nl))
            for entry in wanted { lines += newLines(entry) }
            lines.append(Line(content: endMarker, terminator: nl))
        }
        return Lines(lines: lines, hasBOM: parsed.hasBOM, newline: nl).joined()
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
            /// A user line after the block (or in a file loaded later) wins over the managed
            /// value. Settings can't change this key until the user edits that line.
            case overriddenAfter
            /// A user line after the block adds to the managed value (fallback font, extra
            /// binding for the same action).
            case addsAfter
            /// A user line before the block; the block wins.
            case setBefore
            /// `config-file` includes load after this file and may override anything.
            case include
            /// A line longer than Ghostty reads; Ghostty stops reading the file there, so
            /// the block is never loaded.
            case longLine
        }

        var kind: Kind
        var key: String
        var line: Int
        var value: String
        /// Another file the line is in (nil for the config file being edited).
        var file: String?

        init(kind: Kind, key: String, line: Int, value: String, file: String? = nil) {
            self.kind = kind
            self.key = key
            self.line = line
            self.value = value
            self.file = file
        }

        var id: String { "\(kind)-\(key)-\(file ?? "")-\(line)" }

        private var location: String {
            guard let file else { return "line \(line)" }
            return "\((file as NSString).abbreviatingWithTildeInPath) line \(line)"
        }

        var message: String {
            switch kind {
            case .overriddenAfter:
                if file != nil {
                    return "\(location) sets \(key) and loads after your config; Settings can't change it."
                }
                return "Your config sets \(key) on line \(line) after Slimer's block; Settings can't change it."
            case .addsAfter:
                return "Your config also sets \(key) on \(location) after Slimer's block; it is added to Slimer's value."
            case .setBefore:
                return "Your config sets \(key) on line \(line); Slimer's block comes later and takes precedence."
            case .include:
                return "Line \(line) includes “\(value)”, which loads after this file and can override any setting."
            case .longLine:
                return "Line \(line) is longer than \(GhosttyConfigWriter.maxLineBytes) bytes. Ghostty stops reading the file there, so nothing after it (including Slimer's block) applies."
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
        try analyze(lines: split(text), keys: keys, managedKeybinds: managedKeybinds, keybindActions: keybindActions)
    }

    static func analyze(
        lines parsed: Lines,
        keys: Set<String>,
        managedKeybinds: [String] = [],
        keybindActions: Set<String> = []
    ) throws -> [Finding] {
        let settings = try userSettings(lines: parsed)
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

        // Ghostty stops reading at an over-long line; one before the block (or anywhere,
        // when the block will be appended) hides the block.
        let blockStart = (try blockRange(in: parsed.contents))?.lowerBound ?? parsed.lines.count
        for idx in 0 ..< blockStart where parsed.lines[idx].content.utf8.count > maxLineBytes {
            findings.append(Finding(kind: .longLine, key: "", line: idx + 1, value: ""))
            break
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
