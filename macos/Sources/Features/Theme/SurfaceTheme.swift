import Foundation

/// A per-surface color theme.
///
/// Every field is optional so a theme can be as small as "tint this tab green" or as
/// large as "use the `Catppuccin Mocha` Ghostty theme with a custom cursor and accent".
/// Colors are strict `#RRGGBB` strings. Invalid colors are dropped by ``sanitized()`` and
/// never reach the terminal config (see ``ThemeApplier``).
struct SurfaceTheme: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var name: String

    /// A named Ghostty theme (the `theme` config key). Applied before the colors below so
    /// the explicit colors override the theme file.
    var ghosttyTheme: String?

    /// Terminal colors, `#RRGGBB`.
    var background: String?
    var foreground: String?
    var cursorColor: String?
    var selectionBackground: String?

    /// Accent for the tab indicator / titlebar, `#RRGGBB`. This never touches the terminal
    /// config; it only drives window chrome.
    var accent: String?

    init(
        id: UUID = UUID(),
        name: String,
        ghosttyTheme: String? = nil,
        background: String? = nil,
        foreground: String? = nil,
        cursorColor: String? = nil,
        selectionBackground: String? = nil,
        accent: String? = nil
    ) {
        self.id = id
        self.name = name
        self.ghosttyTheme = ghosttyTheme
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.selectionBackground = selectionBackground
        self.accent = accent
    }

    // MARK: Validation

    /// Strict `#RRGGBB` validation: a leading `#` followed by exactly six hex digits in
    /// either case. No `#RGB`, no alpha, no whitespace, no CSS names.
    static func isValidHex(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 7, scalars[0] == "#" else { return false }
        return scalars[1...].allSatisfy { scalar in
            switch scalar {
            case "0"..."9", "a"..."f", "A"..."F": return true
            default: return false
            }
        }
    }

    /// Returns `value` if it is a valid `#RRGGBB`, otherwise `nil`.
    static func validHex(_ value: String?) -> String? {
        guard let value, isValidHex(value) else { return nil }
        return value
    }

    /// A copy of this theme with every invalid color removed and the name trimmed. The
    /// Ghostty theme name is kept as an opaque string; Ghostty itself validates it.
    func sanitized() -> SurfaceTheme {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.ghosttyTheme = ghosttyTheme.flatMap { Self.sanitizedThemeName($0) }
        copy.background = Self.validHex(background)
        copy.foreground = Self.validHex(foreground)
        copy.cursorColor = Self.validHex(cursorColor)
        copy.selectionBackground = Self.validHex(selectionBackground)
        copy.accent = Self.validHex(accent)
        return copy
    }

    /// Ghostty theme names are plain strings (file names under a themes dir, or a
    /// `light:…,dark:…` pair). Reject anything with control characters so a name can never
    /// smuggle a second config line, and drop empty names.
    static func sanitizedThemeName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    /// True if the theme changes anything about the terminal config (as opposed to only
    /// carrying an accent).
    var affectsTerminalConfig: Bool {
        ghosttyTheme != nil || background != nil || foreground != nil ||
            cursorColor != nil || selectionBackground != nil
    }
}

// MARK: - Rules

/// Automatically applies a theme to surfaces that match. Rules are evaluated by
/// ``ThemeRuleMatcher``; see `docs/slimer/THEMES.md` for the semantics.
struct ThemeRule: Codable, Equatable, Hashable, Identifiable {
    enum Match: Equatable, Hashable {
        /// The surface's working directory is at or below this path. `~` is expanded.
        case pathPrefix(String)
        /// The local machine's host name (short or fully qualified) equals this, or the
        /// surface title contains `@<hostname>` (e.g. an SSH session).
        case hostname(String)
        /// The surface title (as set by the shell or program) names this command.
        case command(String)

        var kind: String {
            switch self {
            case .pathPrefix: return "pathPrefix"
            case .hostname: return "hostname"
            case .command: return "command"
            }
        }

        var value: String {
            switch self {
            case .pathPrefix(let v), .hostname(let v), .command(let v): return v
            }
        }
    }

    var id: UUID
    var match: Match
    var themeId: UUID
    /// Higher wins. Ties are broken by specificity, then file order.
    var priority: Int

    init(id: UUID = UUID(), match: Match, themeId: UUID, priority: Int = 0) {
        self.id = id
        self.match = match
        self.themeId = themeId
        self.priority = priority
    }
}

extension ThemeRule.Match: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    enum DecodingError: Error {
        case unknownKind(String)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        switch kind {
        case "pathPrefix": self = .pathPrefix(value)
        case "hostname": self = .hostname(value)
        case "command": self = .command(value)
        default: throw DecodingError.unknownKind(kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(value, forKey: .value)
    }
}

// MARK: - File document

/// The on-disk shape of `themes.json`. Decoding is tolerant: a malformed theme or rule is
/// skipped rather than failing the whole file, and unknown keys are ignored. Everything
/// skipped or altered is counted in ``droppedEntries`` so the store can refuse to rewrite a
/// file it would damage.
struct ThemeDocument: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var themes: [SurfaceTheme]
    var rules: [ThemeRule]

    /// Not encoded. Number of entries/keys that decoding dropped or changed.
    var droppedEntries = 0

    init(version: Int = ThemeDocument.currentVersion, themes: [SurfaceTheme], rules: [ThemeRule]) {
        self.version = version
        self.themes = themes
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case themes
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        var dropped = 0

        let rawThemes = try container.decodeIfPresent([Lossy<SurfaceTheme>].self, forKey: .themes) ?? []
        let decodedThemes = rawThemes.compactMap(\.value)
        dropped += rawThemes.count - decodedThemes.count
        themes = decodedThemes.map { $0.sanitized() }
        dropped += zip(decodedThemes, themes).filter { $0 != $1 }.count

        let rawRules = try container.decodeIfPresent([Lossy<ThemeRule>].self, forKey: .rules) ?? []
        rules = rawRules.compactMap(\.value)
        dropped += rawRules.count - rules.count

        // Deduplicate ids (first wins) and drop rules pointing at unknown themes.
        var seen = Set<UUID>()
        let themeCount = themes.count
        themes = themes.filter { seen.insert($0.id).inserted }
        dropped += themeCount - themes.count
        let themeIds = seen
        var seenRules = Set<UUID>()
        let ruleCount = rules.count
        rules = rules.filter { themeIds.contains($0.themeId) && seenRules.insert($0.id).inserted }
        dropped += ruleCount - rules.count

        droppedEntries = dropped
    }

    static func == (lhs: ThemeDocument, rhs: ThemeDocument) -> Bool {
        lhs.version == rhs.version && lhs.themes == rhs.themes && lhs.rules == rhs.rules
    }

    private static let topLevelKeys: Set<String> = ["version", "themes", "rules"]
    private static let themeKeys: Set<String> = [
        "id", "name", "ghosttyTheme", "background", "foreground",
        "cursorColor", "selectionBackground", "accent",
    ]
    private static let ruleKeys: Set<String> = ["id", "match", "themeId", "priority"]
    private static let matchKeys: Set<String> = ["kind", "value"]

    /// Keys in `data` that this version would not write back. Non-object entries are
    /// already counted by the decoder.
    static func unknownKeyCount(in data: Data) -> Int {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        func extra(_ object: Any, _ known: Set<String>) -> Int {
            guard let dict = object as? [String: Any] else { return 0 }
            return dict.keys.filter { !known.contains($0) }.count
        }
        var count = extra(root, topLevelKeys)
        for theme in root["themes"] as? [Any] ?? [] {
            count += extra(theme, themeKeys)
        }
        for rule in root["rules"] as? [Any] ?? [] {
            count += extra(rule, ruleKeys)
            if let dict = rule as? [String: Any], let match = dict["match"] {
                count += extra(match, matchKeys)
            }
        }
        return count
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(themes, forKey: .themes)
        try container.encode(rules, forKey: .rules)
    }

    /// Wraps a Decodable so one bad array element decodes to `nil` instead of throwing.
    struct Lossy<T: Decodable>: Decodable {
        let value: T?

        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }
}
