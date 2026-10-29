import Foundation

/// The Ghostty keys Settings can write, and how each value is validated.
///
/// Every value goes through ``SettingsValidator/validate(key:value:)`` before it reaches
/// ``GhosttyConfigWriter``. The validator returns the canonical form to write, or an error
/// the UI shows next to the control. Nothing unvalidated is ever written.
enum SettingsKeySpec: Equatable {
    case enumeration([String])
    case bool
    /// A decimal number in a closed range.
    case number(ClosedRange<Double>)
    case fontFamily
    case themeName
    case quickTerminalSize
    case backgroundBlur
    /// `global:<trigger>=<action>` or `[global:]<trigger>=unbind`.
    case keybind

    /// Registry of managed keys, in the order they are written to the block.
    static let all: [(key: String, spec: SettingsKeySpec)] = [
        // General
        ("window-inherit-working-directory", .bool),
        ("confirm-close-surface", .enumeration(["true", "false", "always"])),
        // Drawer
        ("quick-terminal-position", .enumeration(["top", "bottom", "left", "right", "center"])),
        ("quick-terminal-size", .quickTerminalSize),
        ("quick-terminal-screen", .enumeration(["main", "mouse", "macos-menu-bar"])),
        ("quick-terminal-animation", .enumeration(["slide", "fade", "none"])),
        ("quick-terminal-animation-easing", .enumeration(["ease-in", "ease-out", "ease-in-out", "linear"])),
        ("quick-terminal-animation-duration", .number(0...1)),
        ("quick-terminal-autohide", .bool),
        ("quick-terminal-tab-bar", .enumeration(["auto", "always", "never"])),
        // Appearance
        ("theme", .themeName),
        ("font-family", .fontFamily),
        ("font-size", .number(4...200)),
        ("background-opacity", .number(0...1)),
        ("background-blur", .backgroundBlur),
        ("macos-titlebar-style", .enumeration(["native", "transparent", "tabs", "hidden"])),
        ("slimer-status-bar", .enumeration(["bottom", "top", "hidden"])),
        // Keybinds go last so they read as one group.
        ("keybind", .keybind),
    ]

    static func spec(for key: String) -> SettingsKeySpec? {
        all.first { $0.key == key }?.spec
    }

    static var orderedKeys: [String] { all.map(\.key) }

    /// Whether a line in Slimer's block belongs to Settings (and may be rewritten). Keys
    /// outside the registry stay untouched. For `keybind`, only `global:` bindings of the
    /// three managed actions and `global:` unbinds in the recorder grammar are Settings';
    /// any other keybind someone adds to the block is kept.
    static func owns(key: String, value: String) -> Bool {
        guard spec(for: key) != nil else { return false }
        guard key == "keybind" else { return true }
        guard let bind = KeybindValue(parsing: value), bind.prefixes == ["global"] else { return false }
        if bind.action == "unbind" { return KeyTrigger.isValid(bind.trigger) }
        return ManagedGlobalAction(rawValue: bind.action) != nil
    }

    /// Allowed values for an enumeration key (empty for other kinds).
    static func allowedValues(for key: String) -> [String] {
        if case .enumeration(let values) = spec(for: key) { return values }
        return []
    }
}

enum SettingsValidationError: Error, Equatable, CustomStringConvertible {
    case unknownKey(String)
    case notAllowed(key: String, value: String, allowed: [String])
    case notANumber(key: String, value: String)
    case outOfRange(key: String, range: ClosedRange<Double>)
    case invalidText(key: String, reason: String)
    case invalidKeybind(String)

    var description: String {
        switch self {
        case .unknownKey(let key):
            return "Settings doesn't manage “\(key)”."
        case .notAllowed(let key, let value, let allowed):
            return "“\(value)” isn't a valid \(key); expected one of \(allowed.joined(separator: ", "))."
        case .notANumber(let key, let value):
            return "“\(value)” isn't a number (\(key))."
        case .outOfRange(let key, let range):
            return "\(key) must be between \(SettingsValidator.format(range.lowerBound)) and \(SettingsValidator.format(range.upperBound))."
        case .invalidText(let key, let reason):
            return "Invalid \(key): \(reason)."
        case .invalidKeybind(let value):
            return "“\(value)” isn't a keybind Settings can write."
        }
    }
}

enum SettingsValidator {
    /// Validates `value` for `key` and returns the canonical text to write.
    static func validate(key: String, value: String) -> Result<String, SettingsValidationError> {
        guard let spec = SettingsKeySpec.spec(for: key) else { return .failure(.unknownKey(key)) }
        // Never let a value span lines, whatever the key.
        guard !containsLineBreakOrControl(value) else {
            return .failure(.invalidText(key: key, reason: "contains a line break or control character"))
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        switch spec {
        case .enumeration(let allowed):
            guard allowed.contains(trimmed) else {
                return .failure(.notAllowed(key: key, value: trimmed, allowed: allowed))
            }
            return .success(trimmed)

        case .bool:
            guard trimmed == "true" || trimmed == "false" else {
                return .failure(.notAllowed(key: key, value: trimmed, allowed: ["true", "false"]))
            }
            return .success(trimmed)

        case .number(let range):
            guard let number = parseNumber(trimmed) else {
                return .failure(.notANumber(key: key, value: trimmed))
            }
            guard range.contains(number) else { return .failure(.outOfRange(key: key, range: range)) }
            return .success(format(number))

        case .fontFamily:
            return validateFontFamily(trimmed).map { $0 }

        case .themeName:
            return validateThemeValue(trimmed)

        case .quickTerminalSize:
            return validateQuickTerminalSize(trimmed)

        case .backgroundBlur:
            if ["true", "false", "macos-glass-regular", "macos-glass-clear"].contains(trimmed) {
                return .success(trimmed)
            }
            guard let n = Int(trimmed), (0...100).contains(n) else {
                return .failure(.notAllowed(
                    key: key, value: trimmed,
                    allowed: ["true", "false", "0–100", "macos-glass-regular", "macos-glass-clear"]
                ))
            }
            return .success(String(n))

        case .keybind:
            return validateKeybind(trimmed)
        }
    }

    // MARK: Numbers

    /// Parses a plain decimal (`0.25`, `12`, `-1`) in the POSIX locale. No exponents, no
    /// thousands separators, no `nan`/`inf`.
    static func parseNumber(_ text: String) -> Double? {
        guard !text.isEmpty, text.count <= 16 else { return nil }
        var sawDigit = false
        var sawDot = false
        for (idx, ch) in text.enumerated() {
            switch ch {
            case "0"..."9": sawDigit = true
            case "." where !sawDot: sawDot = true
            case "-" where idx == 0: break
            default: return nil
            }
        }
        guard sawDigit, let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// Up to three decimals, trailing zeros removed, POSIX decimal point.
    static func format(_ value: Double) -> String {
        var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        if text == "-0" { text = "0" }
        return text
    }

    // MARK: Text

    /// True for C0/C1 controls, DEL and Unicode line/paragraph separators.
    static func containsLineBreakOrControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x00...0x1F, 0x7F, 0x80...0x9F, 0x2028, 0x2029: return true
            default: return false
            }
        }
    }

    static func validateFontFamily(_ name: String) -> Result<String, SettingsValidationError> {
        let key = "font-family"
        guard !name.isEmpty else { return .failure(.invalidText(key: key, reason: "empty name")) }
        guard name.count <= 128 else { return .failure(.invalidText(key: key, reason: "longer than 128 characters")) }
        guard !containsLineBreakOrControl(name) else {
            return .failure(.invalidText(key: key, reason: "contains a control character"))
        }
        guard !name.contains("#"), !name.contains("\"") else {
            return .failure(.invalidText(key: key, reason: "contains # or a quote"))
        }
        return .success(name)
    }

    /// A bundled or user theme name, or `light:X,dark:Y`. Names may not look like paths.
    static func validateThemeValue(_ value: String) -> Result<String, SettingsValidationError> {
        let key = "theme"
        func isPlainName(_ name: String) -> Bool {
            GhosttyThemeResolver.isSafeName(name) && !name.contains(",") && !name.contains(":")
                && !name.contains("#") && name == name.trimmingCharacters(in: .whitespaces)
        }
        if isPlainName(value) { return .success(value) }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0].hasPrefix("light:"), parts[1].hasPrefix("dark:") {
            let light = String(parts[0].dropFirst("light:".count))
            let dark = String(parts[1].dropFirst("dark:".count))
            if isPlainName(light), isPlainName(dark) {
                return .success("light:\(light),dark:\(dark)")
            }
        }
        return .failure(.invalidText(key: key, reason: "not a theme name"))
    }

    // MARK: Quick terminal size

    /// One quick-terminal-size component.
    struct SizeComponent: Equatable {
        enum Unit: String { case percent = "%", pixels = "px" }
        var value: Double
        var unit: Unit

        var text: String { "\(SettingsValidator.format(value))\(unit.rawValue)" }

        /// Percent 1–100, pixels 1–10000.
        var isValid: Bool {
            switch unit {
            case .percent: return (1...100).contains(value)
            case .pixels: return (1...10_000).contains(value)
            }
        }

        static func parse(_ text: String) -> SizeComponent? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let unit: Unit
            let number: Substring
            if trimmed.hasSuffix("%") {
                unit = .percent
                number = trimmed.dropLast()
            } else if trimmed.hasSuffix("px") {
                unit = .pixels
                number = trimmed.dropLast(2)
            } else {
                return nil
            }
            guard let value = SettingsValidator.parseNumber(String(number)) else { return nil }
            return SizeComponent(value: value, unit: unit)
        }
    }

    static func validateQuickTerminalSize(_ value: String) -> Result<String, SettingsValidationError> {
        let key = "quick-terminal-size"
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count) else {
            return .failure(.invalidText(key: key, reason: "use one or two sizes like 40% or 40%,800px"))
        }
        var out: [String] = []
        for part in parts {
            guard let component = SizeComponent.parse(part), component.isValid else {
                return .failure(.invalidText(key: key, reason: "sizes are 1–100% or 1–10000px"))
            }
            out.append(component.text)
        }
        return .success(out.joined(separator: ","))
    }

    // MARK: Keybinds

    static func validateKeybind(_ value: String) -> Result<String, SettingsValidationError> {
        guard let bind = KeybindValue(parsing: value) else { return .failure(.invalidKeybind(value)) }
        guard bind.prefixes.allSatisfy({ $0 == "global" }), bind.prefixes.count <= 1 else {
            return .failure(.invalidKeybind(value))
        }
        let isGlobal = bind.prefixes == ["global"]
        if bind.action == "unbind" {
            guard KeyTrigger.isValid(bind.trigger) else { return .failure(.invalidKeybind(value)) }
            return .success((isGlobal ? "global:" : "") + "\(bind.trigger)=unbind")
        }
        guard isGlobal,
              ManagedGlobalAction(rawValue: bind.action) != nil,
              KeyTrigger.globalHotkeyError(bind.trigger) == nil else {
            return .failure(.invalidKeybind(value))
        }
        return .success("global:\(bind.trigger)=\(bind.action)")
    }
}
