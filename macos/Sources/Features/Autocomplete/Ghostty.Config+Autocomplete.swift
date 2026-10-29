import AppKit
import GhosttyKit

extension Ghostty.Config {
    /// `autocomplete`: Slimer ships it on by default.
    var autocompleteEnabled: Bool {
        guard let config = self.config else { return true }
        var v = true
        let key = "autocomplete"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return v
    }

    /// `autocomplete-max-items`, clamped to 1...8.
    var autocompleteMaxItems: Int {
        guard let config = self.config else { return 8 }
        var v: UInt32 = 8
        let key = "autocomplete-max-items"
        _ = ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8)))
        return max(1, min(8, Int(v)))
    }

    /// `autocomplete-enter`.
    var autocompleteEnter: AutocompleteEnterMode {
        guard let config = self.config else { return .accept }
        var v: UnsafePointer<Int8>?
        let key = "autocomplete-enter"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))),
              let ptr = v else { return .accept }
        return AutocompleteEnterMode(rawValue: String(cString: ptr)) ?? .accept
    }

    /// The configured `foreground`, for the popup's text.
    var autocompleteForeground: NSColor? {
        guard let config = self.config else { return nil }
        var color: ghostty_config_color_s = .init()
        let key = "foreground"
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return NSColor(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1
        )
    }
}
