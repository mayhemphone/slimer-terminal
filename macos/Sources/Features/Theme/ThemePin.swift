import Foundation

/// What a surface is explicitly pinned to (rules no longer apply to it).
///
/// Stored in user defaults as one dictionary per surface (see ``ThemeController``):
///
/// - `{"theme": "<uuid>", "at": …}`: a themes.json theme (the original format);
/// - `{"theme": "", "at": …}`: "None (use config)";
/// - `{"theme": "", "ghostty": "<name>", "at": …}`: a Ghostty theme by file name. An older
///   Slimer that doesn't know `ghostty` reads this as "None", which is safe.
///
/// The stored values are untrusted (defaults can be edited by hand or synced): a Ghostty
/// name must be a plain theme file name (``GhosttyThemeResolver/isPlainName(_:)``) or the
/// pin decodes as ``none``. The name is only ever resolved to colors by
/// ``GhosttyThemeResolver``; it never reaches libghostty.
enum ThemePin: Hashable {
    /// "None (use config)": the app's base config.
    case none
    /// A theme from themes.json, by id.
    case theme(UUID)
    /// A Ghostty theme by file name, applied colors-only.
    case ghostty(String)

    static let themeKey = "theme"
    static let ghosttyKey = "ghostty"

    /// Decodes a stored entry. Unknown or malformed values fall back to ``none`` (the base
    /// config), matching how a garbage `theme` value has always been read.
    init(storedEntry entry: [String: Any]) {
        if let raw = entry[Self.ghosttyKey] as? String {
            if let name = Self.validGhosttyName(raw) {
                self = .ghostty(name)
            } else {
                self = .none
            }
            return
        }
        let raw = entry[Self.themeKey] as? String ?? ""
        if let id = UUID(uuidString: raw) {
            self = .theme(id)
        } else {
            self = .none
        }
    }

    /// The fields to store for this pin (the caller adds the `at` timestamp).
    var storedFields: [String: Any] {
        switch self {
        case .none: return [Self.themeKey: ""]
        case .theme(let id): return [Self.themeKey: id.uuidString]
        case .ghostty(let name): return [Self.themeKey: "", Self.ghosttyKey: name]
        }
    }

    /// `name` if it is a plain Ghostty theme file name (no paths, pairs, control characters),
    /// else nil.
    static func validGhosttyName(_ name: String) -> String? {
        guard let clean = SurfaceTheme.sanitizedThemeName(name), clean == name,
              GhosttyThemeResolver.isPlainName(clean) else { return nil }
        return clean
    }

    /// Fixed id for the synthetic ``SurfaceTheme`` a Ghostty pin is applied as. Never used
    /// by a preset, and themes.json ids are never compared against it for pins.
    static let ghosttyThemeId = UUID(uuid: (0x5A, 0x11, 0xAE, 0x00, 0x60, 0x57, 0x40, 0x00,
                                            0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))

    /// The colors-only theme a Ghostty pin applies: just the name, nothing else, so the
    /// resolver's allowlist is the only thing that decides what is applied.
    static func surfaceTheme(forGhosttyName name: String) -> SurfaceTheme {
        SurfaceTheme(id: ghosttyThemeId, name: name, ghosttyTheme: name)
    }
}
