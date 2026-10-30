import Foundation
import GhosttyKit

extension Ghostty.Config {
    /// `slimer-status-bar`: where the per-surface status bar goes.
    enum SlimerStatusBarPosition: String {
        case bottom
        case top
        case hidden
    }

    var slimerStatusBar: SlimerStatusBarPosition {
        let defaultValue = SlimerStatusBarPosition.bottom
        guard let config = self.config else { return defaultValue }
        var v: UnsafePointer<Int8>?
        let key = "slimer-status-bar"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return defaultValue }
        guard let ptr = v else { return defaultValue }
        return SlimerStatusBarPosition(rawValue: String(cString: ptr)) ?? defaultValue
    }

    /// `slimer-status-bar-font-size`: point size of the bar's text (9...24, clamped by the core).
    var slimerStatusBarFontSize: CGFloat {
        let defaultValue: CGFloat = 13
        guard let config = self.config else { return defaultValue }
        var v: Double = 13
        let key = "slimer-status-bar-font-size"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return defaultValue }
        return CGFloat(v)
    }
}
