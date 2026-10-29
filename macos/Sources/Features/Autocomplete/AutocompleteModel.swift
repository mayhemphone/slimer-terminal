import AppKit
import GhosttyKit

/// Slimer autocomplete: plain data and decisions used by the popup, kept free
/// of AppKit views so they can be unit tested.

/// Mirrors `ghostty_autocomplete_kind_e`.
enum AutocompleteKind: UInt8 {
    case subcommand = 0
    case option = 1
    case arg = 2
    case path = 3
    case history = 4
    case generator = 5

    /// A one-glyph icon drawn at the start of each row.
    var icon: String {
        switch self {
        case .subcommand: return "›"
        case .option: return "-"
        case .arg: return "•"
        case .path: return "/"
        case .history: return "◷"
        case .generator: return "⎇"
        }
    }
}

struct AutocompleteItem: Equatable {
    /// Text sent to the shell. For history items this is the whole line.
    let text: String
    let display: String
    let description: String
    let kind: AutocompleteKind
    let dangerous: Bool
    /// UTF-8 bytes at the start of `display` that matched what was typed.
    let matchLength: Int

    /// History suggestions replace the whole line; everything else the token.
    var replacesLine: Bool { kind == .history }
}

struct AutocompleteSuggestions: Equatable {
    var items: [AutocompleteItem]
    /// The replaced token, in characters, and its width in cells.
    var replaceStart: Int
    var replaceLength: Int
    var replaceColumns: Int
    var generation: UInt64
}

/// A snapshot of the shell-reported command line.
struct AutocompleteBuffer: Equatable {
    var text: String
    /// Character (code point) index, as reported by zle.
    var cursor: Int

    /// The characters `[start, start + length)` of the buffer.
    func slice(start: Int, length: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        guard start >= 0, length >= 0, start <= scalars.count else { return "" }
        let end = min(scalars.count, start + length)
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[start..<end])
        return String(out)
    }

    var cursorAtEnd: Bool { cursor >= text.unicodeScalars.count }
}

enum AutocompleteText {
    /// Longest string we draw for any field.
    static let maxDisplayScalars = 200

    /// Replace control, format, separator, private-use and unassigned
    /// characters with U+FFFD so nothing in a suggestion can reorder or hide
    /// text in the popup. Long strings are cut with an ellipsis.
    static func sanitize(_ string: String) -> String {
        var out = String.UnicodeScalarView()
        var count = 0
        for scalar in string.unicodeScalars {
            if count == maxDisplayScalars {
                out.append("…")
                break
            }
            out.append(isDisplaySafe(scalar) ? scalar : "\u{FFFD}")
            count += 1
        }
        return String(out)
    }

    static func isDisplaySafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator,
             .privateUse, .surrogate, .unassigned:
            return false
        default:
            return !scalar.properties.isNoncharacterCodePoint
        }
    }

    /// Split `display` after `matchLength` UTF-8 bytes, never inside a
    /// character. Out-of-range lengths clamp.
    static func splitMatched(_ display: String, matchLength: Int) -> (matched: String, rest: String) {
        guard matchLength > 0 else { return ("", display) }
        var bytes = 0
        var index = display.startIndex
        while index < display.endIndex {
            let next = display.index(after: index)
            let size = display[index..<next].utf8.count
            if bytes + size > matchLength { break }
            bytes += size
            index = next
        }
        return (String(display[..<index]), String(display[index...]))
    }
}

enum AutocompleteSelection {
    /// The item Tab (or Right at the end of the line) inserts when nothing
    /// was selected by navigation: the first item that is neither a
    /// whole-line history entry nor dangerous. Nothing is ever highlighted
    /// before the user navigates.
    static func top(_ items: [AutocompleteItem]) -> Int? {
        items.firstIndex { !$0.dangerous && !$0.replacesLine }
    }

    static func next(_ current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return (current + 1) % count
    }

    static func previous(_ current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return count - 1 }
        return (current - 1 + count) % count
    }
}

enum AutocompleteVisibility {
    /// Show only with a non-empty buffer and at least one suggestion that
    /// would change something. An empty token (right after a space) only
    /// shows when the user asked with Tab.
    static func shouldShow(
        buffer: AutocompleteBuffer,
        suggestions: AutocompleteSuggestions,
        requested: Bool = false
    ) -> Bool {
        guard !buffer.text.isEmpty, !suggestions.items.isEmpty else { return false }
        let token = buffer.slice(start: suggestions.replaceStart, length: suggestions.replaceLength)
        if token.isEmpty && !requested && !suggestions.items.contains(where: { $0.replacesLine }) {
            return false
        }
        return suggestions.items.contains { item in
            item.replacesLine ? item.text != buffer.text : item.text != token
        }
    }

    /// True when suggestions exist but are held back because the token is
    /// empty, so Tab should open the popup instead of going to the shell.
    static func canOpenWithTab(buffer: AutocompleteBuffer, suggestions: AutocompleteSuggestions) -> Bool {
        !shouldShow(buffer: buffer, suggestions: suggestions)
            && shouldShow(buffer: buffer, suggestions: suggestions, requested: true)
    }
}

/// `autocomplete-enter`.
enum AutocompleteEnterMode: String {
    /// Enter runs the command unless a row was selected by navigation.
    case navigated
    /// Enter inserts the selected row, or the top one.
    case accept
    /// Enter always runs the command.
    case passthrough
}

enum AutocompleteKeyAction: Equatable {
    case next
    case previous
    /// Insert the row selected by navigation.
    case acceptSelected
    /// Insert the top acceptable row (see `AutocompleteSelection.top`).
    case acceptTop
    /// Hide the popup and consume the key.
    case dismiss
    /// Hide the popup and let the key through (Esc in vi keymaps, Enter
    /// that runs the command).
    case hideAndPassthrough
    /// Show the held-back popup (Tab on an empty token).
    case open
    /// Not ours: let the key flow to the terminal as usual.
    case passthrough
}

/// What a key does with the popup. Pure so it can be tested.
enum AutocompleteKeys {
    static let tab: UInt16 = 48
    static let enter: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let escape: UInt16 = 53
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let right: UInt16 = 124

    struct Context {
        var visible: Bool
        /// A row was selected by navigation in the current generation.
        var navigated: Bool
        /// There is a top acceptable row for Tab.
        var hasTop: Bool
        var cursorAtEnd: Bool
        /// The shell is in a vi keymap, where Esc means something.
        var viKeymap: Bool
        /// Suggestions are held back for an empty token.
        var canOpen: Bool
        var enterMode: AutocompleteEnterMode
    }

    static func action(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        context c: Context
    ) -> AutocompleteKeyAction {
        let mods = modifiers.intersection([.shift, .control, .option, .command])

        guard c.visible else {
            if c.canOpen, keyCode == tab, mods.isEmpty { return .open }
            return .passthrough
        }

        if mods == .control {
            switch characters?.lowercased() {
            case "n", "\u{0e}": return .next
            case "p", "\u{10}": return .previous
            default: return .passthrough
            }
        }

        let acceptRow: AutocompleteKeyAction = c.navigated ? .acceptSelected : (c.hasTop ? .acceptTop : .passthrough)
        switch keyCode {
        case tab:
            if mods == .shift { return .previous }
            return mods.isEmpty ? acceptRow : .passthrough
        case down:
            return mods.isEmpty ? .next : .passthrough
        case up:
            return mods.isEmpty ? .previous : .passthrough
        case escape:
            guard mods.isEmpty else { return .passthrough }
            return c.viKeymap ? .hideAndPassthrough : .dismiss
        case enter, keypadEnter:
            guard mods.isEmpty else { return .passthrough }
            switch c.enterMode {
            case .navigated: return c.navigated ? .acceptSelected : .hideAndPassthrough
            case .accept:
                if c.navigated { return .acceptSelected }
                return c.hasTop ? .acceptTop : .hideAndPassthrough
            case .passthrough: return .hideAndPassthrough
            }
        case right:
            guard mods.isEmpty, c.cursorAtEnd else { return .passthrough }
            return acceptRow
        default:
            return .passthrough
        }
    }
}

extension AutocompleteSuggestions {
    /// Copy a C result into Swift values (the C strings are only valid until
    /// the next query). `maxItems` applies `autocomplete-max-items`.
    init(_ result: ghostty_autocomplete_result_s, maxItems: Int) {
        var result = result
        let count = min(Int(result.count), Int(GHOSTTY_AUTOCOMPLETE_MAX_ITEMS), max(1, min(8, maxItems)))
        var items: [AutocompleteItem] = []
        withUnsafeBytes(of: &result.items) { raw in
            let cItems = raw.bindMemory(to: ghostty_autocomplete_item_s.self)
            for index in 0..<count {
                let c = cItems[index]
                items.append(AutocompleteItem(
                    text: Self.string(c.text, c.text_len),
                    display: Self.string(c.display, c.display_len),
                    description: Self.string(c.description, c.description_len),
                    kind: AutocompleteKind(rawValue: c.kind) ?? .arg,
                    dangerous: c.dangerous,
                    matchLength: Int(c.match_len)
                ))
            }
        }
        self.init(
            items: items,
            replaceStart: Int(result.replace_start),
            replaceLength: Int(result.replace_len),
            replaceColumns: Int(result.replace_cols),
            generation: result.generation
        )
    }

    private static func string(_ ptr: UnsafePointer<CChar>?, _ len: UInt) -> String {
        guard let ptr, len > 0 else { return "" }
        return ptr.withMemoryRebound(to: UInt8.self, capacity: Int(len)) {
            String(bytes: UnsafeBufferPointer(start: $0, count: Int(len)), encoding: .utf8) ?? ""
        }
    }
}
