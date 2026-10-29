import Foundation
import GhosttyKit

/// Reads the value Ghostty is actually using for a managed key, as canonical text that
/// can be compared with what Settings wrote. Returns nil for keys the C API can't report
/// (`theme`, `font-family`, `keybind`); those are only checked through diagnostics.
enum EffectiveConfigReader {
    static func value(for key: String, in config: Ghostty.Config) -> String? {
        guard let cfg = config.config else { return nil }
        guard let spec = SettingsKeySpec.spec(for: key) else { return nil }
        switch spec {
        case .enumeration:
            var ptr: UnsafePointer<Int8>?
            guard get(cfg, key, &ptr), let ptr else { return nil }
            return String(cString: ptr)

        case .bool:
            var v = false
            guard get(cfg, key, &v) else { return nil }
            return v ? "true" : "false"

        case .number:
            if key == "font-size" {
                var v: Float = 0
                guard get(cfg, key, &v) else { return nil }
                return SettingsValidator.format(Double(v))
            }
            var v: Double = 0
            guard get(cfg, key, &v) else { return nil }
            return SettingsValidator.format(v)

        case .backgroundBlur:
            var v: Int16 = 0
            guard get(cfg, key, &v) else { return nil }
            switch v {
            case 0: return "false"
            case -1: return "macos-glass-regular"
            case -2: return "macos-glass-clear"
            default: return String(v)
            }

        case .quickTerminalSize:
            var v = ghostty_config_quick_terminal_size_s()
            guard get(cfg, key, &v) else { return nil }
            let parts = [v.primary, v.secondary].compactMap(sizeText)
            return parts.isEmpty ? nil : parts.joined(separator: ",")

        case .fontFamily, .themeName, .keybind:
            return nil
        }
    }

    /// Whether `effective` is what Ghostty would load for the `written` value.
    static func matches(key: String, written: String, effective: String) -> Bool {
        if written == effective { return true }
        switch SettingsKeySpec.spec(for: key) {
        case .backgroundBlur:
            // `true` loads as radius 20.
            return written == "true" && effective == "20"
        case .number:
            guard let a = Double(written), let b = Double(effective) else { return false }
            return abs(a - b) < 0.001
        default:
            return false
        }
    }

    private static func sizeText(_ size: ghostty_quick_terminal_size_s) -> String? {
        switch size.tag {
        case GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE:
            return "\(SettingsValidator.format(Double(size.value.percentage)))%"
        case GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS:
            return "\(size.value.pixels)px"
        default:
            return nil
        }
    }

    private static func get<T>(_ cfg: ghostty_config_t, _ key: String, _ out: inout T) -> Bool {
        ghostty_config_get(cfg, &out, key, UInt(key.lengthOfBytes(using: .utf8)))
    }
}
