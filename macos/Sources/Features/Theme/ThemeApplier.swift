import Foundation
import GhosttyKit

/// Builds per-surface Ghostty configs for a ``SurfaceTheme``.
///
/// A themed config is a clone of an already-loaded base config (normally the app's), with
/// color-only `key=value` args applied through `ghostty_config_load_arg` and then finalized.
/// Nothing is read from the user's config files, and no theme name or path ever reaches
/// libghostty: named Ghostty themes are resolved by ``GhosttyThemeResolver`` into color args.
///
/// Order: the named theme's colors first, then the theme's explicit colors, so explicit
/// values always win. Because `ghostty_config_load_arg` records its args as replay steps
/// after the user's own config, they also win over the user's config, including when the
/// core re-derives the config for a light/dark conditional change.
enum ThemeApplier {
    /// Pure: the ordered `key=value` strings for `theme`, given the color args already
    /// resolved from its named Ghostty theme (if any). The `accent` field is chrome-only and
    /// never emitted.
    static func configArgs(for theme: SurfaceTheme, namedThemeArgs: [String] = []) -> [String] {
        var args = namedThemeArgs
        if let v = SurfaceTheme.validHex(theme.background) { args.append("background=\(v)") }
        if let v = SurfaceTheme.validHex(theme.foreground) { args.append("foreground=\(v)") }
        if let v = SurfaceTheme.validHex(theme.cursorColor) { args.append("cursor-color=\(v)") }
        if let v = SurfaceTheme.validHex(theme.selectionBackground) {
            args.append("selection-background=\(v)")
        }
        return args
    }

    /// A finalized clone of `base` with `args` applied. The caller owns the result.
    static func makeConfig(base: ghostty_config_t, args: [String]) -> Ghostty.Config? {
        let config = Ghostty.Config(clone: base)
        guard let cfg = config.config else { return nil }
        for arg in args where !ghostty_config_load_arg(cfg, arg) {
            ThemeStore.logger.warning("theme: rejected config arg \(arg, privacy: .public)")
        }
        ghostty_config_finalize(cfg)
        return config
    }
}
