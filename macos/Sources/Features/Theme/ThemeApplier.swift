import Foundation
import GhosttyKit

/// Turns a ``SurfaceTheme`` into a per-surface Ghostty config and pushes it to one surface
/// with `ghostty_surface_update_config`. Other surfaces are untouched.
///
/// Base config selection:
/// - A theme that only sets colors is layered on a **clone of the app's current config**
///   (`ghostty_config_clone`), so nothing is read from disk.
/// - A theme that sets a named `ghosttyTheme` is layered on a **fresh, unfinalized load of
///   the user's config files**. Ghostty resolves `theme=` during `finalize` by replaying the
///   user's own config lines on top of the theme file; starting from an already finalized
///   clone would replay the user's *previous* theme's colors over the new one.
///
/// In both cases the explicit colors come last, so they override both the user's config
/// and the named theme.
enum ThemeApplier {
    /// Pure: the ordered `key=value` strings for `theme`. Only valid, set fields are
    /// emitted; the Ghostty theme (if any) comes first so the colors override it. The
    /// `accent` field is chrome-only and never emitted.
    static func configArgs(for theme: SurfaceTheme) -> [String] {
        var args: [String] = []
        if let name = theme.ghosttyTheme.flatMap({ SurfaceTheme.sanitizedThemeName($0) }) {
            args.append("theme=\(name)")
        }
        if let v = SurfaceTheme.validHex(theme.background) { args.append("background=\(v)") }
        if let v = SurfaceTheme.validHex(theme.foreground) { args.append("foreground=\(v)") }
        if let v = SurfaceTheme.validHex(theme.cursorColor) { args.append("cursor-color=\(v)") }
        if let v = SurfaceTheme.validHex(theme.selectionBackground) {
            args.append("selection-background=\(v)")
        }
        return args
    }

    /// Applies `theme` to `surfaceView`. Passing `nil` (or a theme with no terminal fields)
    /// restores the app's base config for that surface.
    ///
    /// - Returns: false if the surface has no live core handle or no config could be built.
    @discardableResult
    static func apply(theme: SurfaceTheme?, to surfaceView: Ghostty.SurfaceView, app: Ghostty.App) -> Bool {
        guard let surface = surfaceView.surface else { return false }
        guard let base = app.config.config else { return false }

        guard let theme, theme.affectsTerminalConfig else {
            ghostty_surface_update_config(surface, base)
            return true
        }

        let args = configArgs(for: theme)
        guard let config = makeConfig(usingFreshLoad: theme.ghosttyTheme != nil, base: base) else {
            ThemeStore.logger.warning("theme apply: could not create config")
            return false
        }
        guard let cfg = config.config else { return false }

        for arg in args where !ghostty_config_load_arg(cfg, arg) {
            ThemeStore.logger.warning("theme apply: rejected arg \(arg, privacy: .public)")
        }
        ghostty_config_finalize(cfg)
        ghostty_surface_update_config(surface, cfg)
        // `config` frees the C object when it goes out of scope; the core copied what it needs.
        return true
    }

    /// Mirrors how `Ghostty.App` finds the user's config: `GHOSTTY_CONFIG_PATH` overrides the
    /// default locations.
    static var configPath: String? {
        ProcessInfo.processInfo.environment["GHOSTTY_CONFIG_PATH"]
    }

    private static func makeConfig(usingFreshLoad: Bool, base: ghostty_config_t) -> Ghostty.Config? {
        let config: Ghostty.Config
        if usingFreshLoad {
            config = Ghostty.Config(at: configPath, finalize: false)
        } else {
            config = Ghostty.Config(clone: base)
        }
        return config.loaded ? config : nil
    }
}
