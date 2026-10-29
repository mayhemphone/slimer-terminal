import AppKit
import GhosttyKit

extension Ghostty.Config {
    /// `slimer-shortcut-overlay`: which modifier, held alone, shows the shortcut sheet.
    enum SlimerShortcutOverlay: String, CaseIterable {
        case ctrl
        case cmd
        case option
        case off

        /// The modifier to hold, or nil when the sheet is off.
        var modifier: NSEvent.ModifierFlags? {
            switch self {
            case .ctrl: return .control
            case .cmd: return .command
            case .option: return .option
            case .off: return nil
            }
        }
    }

    var slimerShortcutOverlay: SlimerShortcutOverlay {
        let defaultValue = SlimerShortcutOverlay.ctrl
        guard let config = self.config else { return defaultValue }
        var v: UnsafePointer<Int8>?
        let key = "slimer-shortcut-overlay"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return defaultValue }
        guard let ptr = v else { return defaultValue }
        return SlimerShortcutOverlay(rawValue: String(cString: ptr)) ?? defaultValue
    }

    /// `slimer-shortcut-overlay-delay` in seconds.
    var slimerShortcutOverlayDelay: TimeInterval {
        let defaultValue: TimeInterval = 2
        guard let config = self.config else { return defaultValue }
        var v: UInt = 0
        let key = "slimer-shortcut-overlay-delay"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return defaultValue }
        return TimeInterval(v) / 1000
    }

    /// One configured top-level keybind, read through `ghostty_config_keybind_at`.
    struct SlimerKeybind {
        let trigger: ghostty_input_trigger_s
        /// The action in config syntax, e.g. `goto_split:left`. Display only.
        let action: String
        let isGlobal: Bool
    }

    /// Every top-level keybind (sequences are skipped). Read-only; call off the hot path.
    var slimerKeybinds: [SlimerKeybind] {
        guard let config = self.config else { return [] }
        let count = ghostty_config_keybind_count(config)
        guard count > 0 else { return [] }
        var result: [SlimerKeybind] = []
        result.reserveCapacity(Int(count))
        var buffer = [CChar](repeating: 0, count: 256)
        for index in 0..<count {
            var out = ghostty_config_keybind_s()
            let ok = buffer.withUnsafeMutableBufferPointer { buf in
                ghostty_config_keybind_at(config, index, &out, buf.baseAddress, UInt(buf.count))
            }
            guard ok else { continue }
            // NUL-terminated by libghostty; invalid UTF-8 from truncation is repaired.
            let action = buffer.withUnsafeBufferPointer { buf in
                buf.baseAddress.map { String(cString: $0) } ?? ""
            }
            result.append(SlimerKeybind(
                trigger: out.trigger,
                action: action,
                isGlobal: (UInt32(out.flags) & GHOSTTY_BINDING_FLAGS_GLOBAL.rawValue) != 0
            ))
        }
        return result
    }
}
