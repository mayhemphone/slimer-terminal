import Cocoa
import GhosttyKit

// slimer: Swift side of the `quick-terminal-animation` and
// `quick-terminal-animation-easing` config keys.

/// `quick-terminal-animation`: how the drawer enters and leaves the screen.
enum QuickTerminalAnimation: String {
    /// Slide in from the screen edge (historical behavior).
    case slide
    /// Fade alpha in place at the final frame.
    case fade
    /// Appear and disappear instantly.
    case none
}

/// `quick-terminal-animation-easing`: the timing curve of the drawer animation.
enum QuickTerminalAnimationEasing: String {
    case easeIn = "ease-in"
    case easeOut = "ease-out"
    case easeInOut = "ease-in-out"
    case linear

    var timingFunction: CAMediaTimingFunction {
        switch self {
        case .easeIn: return .init(name: .easeIn)
        case .easeOut: return .init(name: .easeOut)
        case .easeInOut: return .init(name: .easeInEaseOut)
        case .linear: return .init(name: .linear)
        }
    }
}

extension Ghostty.Config {
    var quickTerminalAnimation: QuickTerminalAnimation {
        guard let config = self.config else { return .slide }
        var v: UnsafePointer<Int8>?
        let key = "quick-terminal-animation"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return .slide }
        guard let ptr = v else { return .slide }
        return QuickTerminalAnimation(rawValue: String(cString: ptr)) ?? .slide
    }

    var quickTerminalAnimationEasing: QuickTerminalAnimationEasing {
        guard let config = self.config else { return .easeIn }
        var v: UnsafePointer<Int8>?
        let key = "quick-terminal-animation-easing"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return .easeIn }
        guard let ptr = v else { return .easeIn }
        return QuickTerminalAnimationEasing(rawValue: String(cString: ptr)) ?? .easeIn
    }
}
