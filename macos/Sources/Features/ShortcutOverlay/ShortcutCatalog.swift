import AppKit
import GhosttyKit

/// One row of the shortcut sheet.
struct ShortcutEntry: Equatable, Identifiable {
    let title: String
    /// Glyph string, e.g. `⌃⇧⌘T`.
    let keys: String
    var isEnabled: Bool = true
    var isGlobal: Bool = false

    var id: String { "\(keys)\u{1F}\(title)" }
}

/// A titled column section of the sheet.
struct ShortcutGroup: Equatable, Identifiable {
    let title: String
    var entries: [ShortcutEntry]

    var id: String { title }
}

/// A normalized key combination, used to tell whether a keybind is already on a menu.
struct ShortcutChord: Hashable {
    let modifiers: UInt
    let key: String

    init(modifiers: NSEvent.ModifierFlags, key: String) {
        self.modifiers = modifiers.intersection([.control, .option, .shift, .command]).rawValue
        self.key = key.lowercased()
    }
}

/// Formats key equivalents with the standard macOS glyphs.
enum ShortcutGlyphs {
    static let modifierOrder: [(flag: NSEvent.ModifierFlags, glyph: String)] = [
        (.control, "⌃"),
        (.option, "⌥"),
        (.shift, "⇧"),
        (.command, "⌘"),
    ]

    /// A menu-style key equivalent (`keyEquivalent` + modifier mask) as glyphs, or nil
    /// when the key can't be shown. An uppercase letter implies Shift, as in AppKit.
    static func format(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) -> String? {
        guard let (key, mods) = normalize(keyEquivalent: keyEquivalent, modifiers: modifiers),
              let glyph = keyGlyph(key) else { return nil }
        return modifierGlyphs(mods) + glyph
    }

    static func modifierGlyphs(_ modifiers: NSEvent.ModifierFlags) -> String {
        modifierOrder.filter { modifiers.contains($0.flag) }.map(\.glyph).joined()
    }

    /// Folds an uppercase letter into Shift so `E` + ⌘ and `e` + ⇧⌘ compare equal.
    static func normalize(
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard keyEquivalent.unicodeScalars.count == 1 || keyEquivalent.count == 1,
              !keyEquivalent.isEmpty else { return nil }
        var mods = modifiers.intersection([.control, .option, .shift, .command])
        let lower = keyEquivalent.lowercased()
        if lower != keyEquivalent, keyEquivalent.uppercased() == keyEquivalent {
            mods.insert(.shift)
        }
        return (lower, mods)
    }

    /// The glyph for a single key equivalent character, or nil for anything unprintable
    /// that has no standard glyph.
    static func keyGlyph(_ key: String) -> String? {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return nil }
        switch Int(scalar.value) {
        case 0x0D, 0x0A: return "↩"
        case 0x03: return "⌤"
        case 0x09: return "⇥"
        case 0x19: return "⇤"
        case 0x1B: return "⎋"
        case 0x08, 0x7F: return "⌫"
        case 0x20: return "Space"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSDeleteFunctionKey: return "⌦"
        case NSHomeFunctionKey: return "↖"
        case NSEndFunctionKey: return "↘"
        case NSPageUpFunctionKey: return "⇞"
        case NSPageDownFunctionKey: return "⇟"
        case NSClearLineFunctionKey: return "⌧"
        case NSF1FunctionKey...NSF35FunctionKey:
            return "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
        default:
            break
        }
        // Any other control or private-use character has no glyph.
        if SlimerUnsafeText.isUnsafe(scalar) { return nil }
        if scalar.properties.generalCategory == .privateUse { return nil }
        return key.uppercased()
    }
}

/// Builds the sheet's content: menu shortcuts, keybinds that aren't on a menu, and the
/// static terminal keys. Runs on show, never per keystroke.
enum ShortcutCatalog {
    static let maxTitleLength = 40

    /// Display text from menus or config: control and format characters removed,
    /// whitespace collapsed, truncated with an ellipsis.
    static func displayTitle(_ text: String, limit: Int = maxTitleLength) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !SlimerUnsafeText.isUnsafe(scalar) {
            scalars.append(scalar)
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(limit - 1, 1))) + "…"
    }

    // MARK: Menus

    /// One group per top-level menu, holding every visible item with a key equivalent
    /// (submenus included). Disabled items are kept and marked; separators and hidden
    /// items are skipped. `chords` collects every shortcut found.
    static func menuGroups(
        from mainMenu: NSMenu,
        appName: String,
        skipping skipped: Set<ObjectIdentifier> = [],
        chords: inout Set<ShortcutChord>
    ) -> [ShortcutGroup] {
        var groups: [ShortcutGroup] = []
        for (index, top) in mainMenu.items.enumerated() {
            guard !top.isHidden, !top.isSeparatorItem, let submenu = top.submenu else { continue }
            var entries: [ShortcutEntry] = []
            var seen = Set<ShortcutChord>()
            collect(submenu, skipping: skipped, into: &entries, seen: &seen)
            guard !entries.isEmpty else { continue }
            chords.formUnion(seen)
            // The application menu's title is filled in by AppKit; use the app name.
            var title = index == 0 ? displayTitle(appName) : displayTitle(top.title.isEmpty ? submenu.title : top.title)
            if title.isEmpty { title = "Menu" }
            groups.append(ShortcutGroup(title: title, entries: entries))
        }
        return groups
    }

    private static func collect(
        _ menu: NSMenu,
        skipping skipped: Set<ObjectIdentifier>,
        into entries: inout [ShortcutEntry],
        seen: inout Set<ShortcutChord>
    ) {
        guard !skipped.contains(ObjectIdentifier(menu)) else { return }
        for item in menu.items {
            guard !item.isSeparatorItem, !item.isHidden else { continue }
            if let submenu = item.submenu {
                collect(submenu, skipping: skipped, into: &entries, seen: &seen)
                continue
            }
            guard !item.keyEquivalent.isEmpty,
                  let (key, mods) = ShortcutGlyphs.normalize(
                    keyEquivalent: item.keyEquivalent,
                    modifiers: item.keyEquivalentModifierMask),
                  let keys = ShortcutGlyphs.format(keyEquivalent: key, modifiers: mods) else { continue }
            let title = displayTitle(item.title)
            guard !title.isEmpty else { continue }
            let chord = ShortcutChord(modifiers: mods, key: key)
            guard seen.insert(chord).inserted else { continue }
            entries.append(ShortcutEntry(title: title, keys: keys, isEnabled: item.isEnabled))
        }
    }

    // MARK: Keybinds

    /// A keybind reduced to what the sheet needs. Built from `Ghostty.Config.SlimerKeybind`
    /// (or directly in tests).
    struct Keybind: Equatable {
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
        let action: String
        let isGlobal: Bool
    }

    /// Converts a libghostty trigger to a menu-style key equivalent.
    @MainActor static func keybind(from bind: Ghostty.Config.SlimerKeybind) -> Keybind? {
        guard let shortcut = Ghostty.keyboardShortcut(for: bind.trigger) else { return nil }
        var mods: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.control) { mods.insert(.control) }
        if shortcut.modifiers.contains(.option) { mods.insert(.option) }
        if shortcut.modifiers.contains(.shift) { mods.insert(.shift) }
        if shortcut.modifiers.contains(.command) { mods.insert(.command) }
        return Keybind(
            keyEquivalent: String(shortcut.key.character),
            modifiers: mods,
            action: bind.action,
            isGlobal: bind.isGlobal)
    }

    /// Actions that do nothing visible or don't apply on macOS.
    static let hiddenActionKeys: Set<String> = ["ignore", "unbind", "cursor_key"]

    /// "Global" for global binds, "Keybinds" for the rest that no menu already shows.
    /// `titles` maps an action (`goto_split:left`) to a friendly title.
    static func keybindGroups(
        _ binds: [Keybind],
        menuChords: Set<ShortcutChord>,
        titles: [String: String],
        unsupportedActionKeys: Set<String> = []
    ) -> [ShortcutGroup] {
        var local: [ShortcutEntry] = []
        var global: [ShortcutEntry] = []
        var seen = Set<String>()
        for bind in binds {
            let actionKey = String(bind.action.prefix { $0 != ":" })
            guard !hiddenActionKeys.contains(actionKey),
                  !unsupportedActionKeys.contains(actionKey),
                  let (key, mods) = ShortcutGlyphs.normalize(keyEquivalent: bind.keyEquivalent, modifiers: bind.modifiers),
                  let keys = ShortcutGlyphs.format(keyEquivalent: key, modifiers: mods) else { continue }
            // A global bind is listed even when a menu shows the same keys, since the
            // menu doesn't say it works from every app.
            if !bind.isGlobal, menuChords.contains(ShortcutChord(modifiers: mods, key: key)) { continue }
            guard seen.insert("\(bind.isGlobal)\(keys)").inserted else { continue }
            let title = displayTitle(titles[bind.action] ?? humanize(bind.action))
            guard !title.isEmpty else { continue }
            let entry = ShortcutEntry(title: title, keys: keys, isGlobal: bind.isGlobal)
            if bind.isGlobal { global.append(entry) } else { local.append(entry) }
        }
        var groups: [ShortcutGroup] = []
        if !global.isEmpty {
            groups.append(ShortcutGroup(title: "Global", entries: sorted(global)))
        }
        if !local.isEmpty {
            groups.append(ShortcutGroup(title: "Keybinds", entries: sorted(local)))
        }
        return groups
    }

    /// Alphabetical by title, then by keys, so related actions (`Focus Split: …`) sit together.
    static func sorted(_ entries: [ShortcutEntry]) -> [ShortcutEntry] {
        entries.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.keys < $1.keys
        }
    }

    /// `goto_split:left` → `Goto split: left`.
    static func humanize(_ action: String) -> String {
        let parts = action.split(separator: ":", maxSplits: 1)
        guard let name = parts.first else { return action }
        var title = name.replacingOccurrences(of: "_", with: " ")
        if let first = title.first { title = first.uppercased() + title.dropFirst() }
        if parts.count > 1 { title += ": " + parts[1] }
        return title
    }

    // MARK: Static terminal keys

    /// Slimer keys that aren't menu items or keybinds. See AUTOCOMPLETE.md.
    static let terminalGroup = ShortcutGroup(title: "In the terminal", entries: [
        ShortcutEntry(title: "Autocomplete: accept", keys: "⇥ / →"),
        ShortcutEntry(title: "Autocomplete: next", keys: "↓ / ⌃N"),
        ShortcutEntry(title: "Autocomplete: previous", keys: "↑ / ⌃P / ⇧⇥"),
        ShortcutEntry(title: "Autocomplete: insert selected", keys: "↩"),
        ShortcutEntry(title: "Autocomplete: hide", keys: "⎋"),
    ])
}
