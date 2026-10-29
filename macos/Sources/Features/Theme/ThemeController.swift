import AppKit
import Combine
import GhosttyKit

extension Notification.Name {
    /// Posted (object: the `Ghostty.SurfaceView`) after a surface's effective theme changed.
    static let slimerSurfaceThemeDidChange = Notification.Name("com.slimer.surfaceThemeDidChange")
}

/// Coordinates themes across every live surface:
///
/// - discovers terminal controllers (normal windows and the quick terminal) and tracks the
///   surfaces in their split trees;
/// - evaluates rules when a surface's `pwd` or `title` changes (debounced 150 ms), unless the
///   user set an explicit theme on that surface (explicit always wins);
/// - re-applies surface themes after a global config reload, which resets every surface to
///   the base config;
/// - pushes the focused surface's accent to its `TerminalWindow`.
///
/// Explicit per-surface choices are remembered in `UserDefaults` keyed by the surface's
/// stable id, so they survive window restoration and undo/redo. Themes and rules themselves
/// live in ``ThemeStore``.
///
/// Main thread only.
final class ThemeController {
    static let shared = ThemeController()

    enum Assignment: Equatable {
        /// Rules decide.
        case automatic
        /// The user picked a theme (`nil` = "None, use config"). Rules are ignored.
        case explicit(UUID?)
    }

    private static let assignmentsKey = "SlimerSurfaceThemes"
    private static let assignmentMaxAge: TimeInterval = 30 * 24 * 60 * 60

    let store: ThemeStore
    private(set) weak var app: Ghostty.App?
    private let defaults: UserDefaults
    private let home: String
    private let localHostnames: [String]

    private var cancellables = Set<AnyCancellable>()
    private var controllers: [ObjectIdentifier: ControllerState] = [:]
    private var surfaces: [UUID: SurfaceState] = [:]

    /// Finalized themed configs built from the app's current config, one per theme and
    /// appearance. Dropped (and freed) when the app config is replaced or the store changes.
    private struct CacheKey: Hashable {
        let theme: SurfaceTheme
        let dark: Bool
    }
    private var configCache: [CacheKey: Ghostty.Config] = [:]
    private var namedThemeCache: [String: [String]?] = [:]
    private weak var cacheBase: Ghostty.Config?
    private var warned = Set<String>()

    private struct ControllerState {
        weak var controller: BaseTerminalController?
        var cancellable: AnyCancellable
    }

    private final class SurfaceState {
        weak var view: Ghostty.SurfaceView?
        var cancellables = Set<AnyCancellable>()
        /// The theme currently pushed to the core. `nil` means the base config.
        var applied: SurfaceTheme?

        init(view: Ghostty.SurfaceView) {
            self.view = view
        }
    }

    init(store: ThemeStore = .shared, defaults: UserDefaults = .ghostty) {
        self.store = store
        self.defaults = defaults
        self.home = FileManager.default.homeDirectoryForCurrentUser.path
        self.localHostnames = ThemeRuleMatcher.localHostnames(from: ProcessInfo.processInfo.hostName)
    }

    // MARK: Lifecycle

    /// Starts tracking. Safe to call more than once.
    func start(app: Ghostty.App) {
        guard self.app == nil else { return }
        self.app = app

        let center = NotificationCenter.default

        // Any of these can mean a new terminal controller exists.
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            TerminalWindow.terminalDidAwake,
        ] {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.rescanControllers() }
                .store(in: &cancellables)
        }

        // A global config reload resets every surface to the base config; put ours back.
        center.publisher(for: .ghosttyConfigDidChange)
            .filter { $0.object == nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reapplyAll() }
            .store(in: &cancellables)

        // Themes or rules changed (locally or by editing the file).
        store.$generation
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.invalidateCaches()
                self?.reevaluateAll()
            }
            .store(in: &cancellables)

        rescanControllers()
    }

    // MARK: Discovery

    private func rescanControllers() {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            register(controller)
        }
        controllers = controllers.filter { $0.value.controller != nil }
    }

    private func register(_ controller: BaseTerminalController) {
        let key = ObjectIdentifier(controller)
        guard controllers[key] == nil else { return }
        let cancellable = controller.$surfaceTree
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tree in self?.track(tree) }
        controllers[key] = ControllerState(controller: controller, cancellable: cancellable)
    }

    private func track(_ tree: SplitTree<Ghostty.SurfaceView>) {
        for view in tree where surfaces[view.id] == nil {
            register(view)
        }
        surfaces = surfaces.filter { $0.value.view != nil }
    }

    private func register(_ view: Ghostty.SurfaceView) {
        let state = SurfaceState(view: view)
        surfaces[view.id] = state
        let id = view.id
        touchAssignment(id)

        view.$pwd
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate(id) }
            .store(in: &state.cancellables)

        // Titles can change continuously (progress output); throttle so the latest value
        // is evaluated at most every 150 ms instead of waiting for a quiet period.
        view.$title
            .removeDuplicates()
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.evaluate(id) }
            .store(in: &state.cancellables)

        // The surface that just gained focus decides the window's accent.
        view.$focusInstant
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushAccent(for: id, force: true) }
            .store(in: &state.cancellables)

        evaluate(id)
    }

    // MARK: Evaluation

    /// The theme a surface should have right now, before considering what is applied.
    func desiredTheme(for view: Ghostty.SurfaceView) -> SurfaceTheme? {
        switch assignment(for: view.id) {
        case .explicit(let themeId):
            guard let themeId else { return nil }
            guard let theme = store.theme(id: themeId) else {
                warnOnce("pin:\(themeId)", "theme: pinned theme \(themeId.uuidString) not found in themes.json")
                return nil
            }
            return theme
        case .automatic:
            let context = ThemeRuleMatcher.Context(
                pwd: view.pwd,
                title: view.title,
                localHostnames: localHostnames
            )
            guard let rule = ThemeRuleMatcher.match(rules: store.rules, context: context, home: home) else {
                return nil
            }
            return store.theme(id: rule.themeId)
        }
    }

    private func evaluate(_ id: UUID, force: Bool = false) {
        guard let state = surfaces[id], let view = state.view, let app else { return }
        let desired = desiredTheme(for: view)

        // Nothing applied and nothing wanted: leave the surface on the base config.
        if desired == nil && state.applied == nil { return }
        if !force && desired == state.applied { return }

        guard apply(desired, to: view, app: app) else { return }
        state.applied = desired
        pushAccent(for: id, force: false)
        NotificationCenter.default.post(name: .slimerSurfaceThemeDidChange, object: view)
    }

    // MARK: Configs

    private var isDark: Bool {
        NSApp.effectiveAppearance.isDark
    }

    private func invalidateCaches() {
        configCache.removeAll()
        namedThemeCache.removeAll()
        warned.removeAll()
    }

    /// Color args from the theme's named Ghostty theme: `[]` if it has none, `nil` if it
    /// names one that can't be resolved safely.
    func namedThemeArgs(for theme: SurfaceTheme, dark: Bool) -> [String]? {
        guard let name = theme.ghosttyTheme else { return [] }
        let key = "\(dark ? "d" : "l"):\(name)"
        if let cached = namedThemeCache[key] { return cached }
        let resolved = GhosttyThemeResolver.colorArgs(
            for: name,
            dark: dark,
            directories: GhosttyThemeResolver.searchDirectories()
        )
        namedThemeCache[key] = .some(resolved)
        if resolved == nil {
            warnOnce("named:\(name)", "theme: Ghostty theme \"\(name)\" not found or not a plain theme name")
        }
        return resolved
    }

    /// True if the theme's named Ghostty theme (if any) resolves. Used by menus.
    func namedThemeResolves(_ theme: SurfaceTheme) -> Bool {
        namedThemeArgs(for: theme, dark: isDark) != nil
    }

    /// A finalized config for `theme` on top of `base`, or nil if the theme changes nothing
    /// (use `base` as is). Configs built on the app's current config are cached per theme
    /// until that config is replaced, so N surfaces sharing a theme share one build.
    func themedConfig(for theme: SurfaceTheme, base: Ghostty.Config) -> Ghostty.Config? {
        guard let baseCfg = base.config else { return nil }
        let cacheable = base === app?.config
        if cacheable && cacheBase !== base {
            configCache.removeAll()
            cacheBase = base
        }
        let dark = isDark
        let key = CacheKey(theme: theme, dark: dark)
        if cacheable, let cached = configCache[key] { return cached }

        let named = namedThemeArgs(for: theme, dark: dark) ?? []
        let args = ThemeApplier.configArgs(for: theme, namedThemeArgs: named)
        guard !args.isEmpty else { return nil }
        guard let config = ThemeApplier.makeConfig(base: baseCfg, args: args) else { return nil }
        if cacheable { configCache[key] = config }
        return config
    }

    /// Hook for `Ghostty.App.reloadConfig(surface:soft:)`. A per-surface reload (e.g. a
    /// light/dark color scheme change) would otherwise push the plain base config and wipe
    /// the surface's theme. Returns nil when the surface has no theme.
    func themedConfig(forSurface surface: ghostty_surface_t, base: Ghostty.Config) -> Ghostty.Config? {
        guard let state = surfaces.values.first(where: { $0.view?.surface == surface }),
              let theme = state.applied else { return nil }
        return themedConfig(for: theme, base: base)
    }

    /// Pushes `theme` (or the base config for nil) to the surface. Returns false if nothing
    /// could be applied.
    private func apply(_ theme: SurfaceTheme?, to view: Ghostty.SurfaceView, app: Ghostty.App) -> Bool {
        guard let surface = view.surface, let base = app.config.config else { return false }
        if let theme, let themed = themedConfig(for: theme, base: app.config), let cfg = themed.config {
            ghostty_surface_update_config(surface, cfg)
        } else {
            ghostty_surface_update_config(surface, base)
        }
        return true
    }

    private func warnOnce(_ key: String, _ message: String) {
        guard warned.insert(key).inserted else { return }
        ThemeStore.logger.warning("\(message, privacy: .public)")
    }

    /// After a global config reload every surface is back on the base config.
    private func reapplyAll() {
        for (id, state) in surfaces where state.applied != nil {
            evaluate(id, force: true)
        }
    }

    private func reevaluateAll() {
        for id in surfaces.keys {
            evaluate(id)
        }
    }

    // MARK: Accent

    /// The accent of the theme currently applied to `view`, if any.
    func accentColor(for view: Ghostty.SurfaceView) -> NSColor? {
        guard let hex = surfaces[view.id]?.applied?.accent else { return nil }
        return NSColor(strictHex: hex)
    }

    /// Pushes the surface's accent to its window. With `force == false` only the window's
    /// focused surface may change the accent.
    private func pushAccent(for id: UUID, force: Bool) {
        guard let view = surfaces[id]?.view else { return }
        guard let window = view.window as? TerminalWindow else { return }
        // Only the window's focused surface may set the accent, unless forced by a focus event.
        guard force || window.terminalController?.focusedSurface === view else { return }
        window.themeAccentColor = accentColor(for: view)
    }

    // MARK: Explicit assignments

    func assignment(for surfaceId: UUID) -> Assignment {
        guard let entry = storedAssignments()[surfaceId.uuidString] else { return .automatic }
        let raw = entry["theme"] as? String ?? ""
        return .explicit(UUID(uuidString: raw))
    }

    /// The theme currently applied to `view` (nil = base config).
    func appliedTheme(for view: Ghostty.SurfaceView) -> SurfaceTheme? {
        surfaces[view.id]?.applied
    }

    /// Pins `themeId` (or "None" when nil) to this surface. Rules no longer apply to it.
    func setExplicitTheme(_ themeId: UUID?, for view: Ghostty.SurfaceView) {
        var all = storedAssignments()
        all[view.id.uuidString] = [
            "theme": themeId?.uuidString ?? "",
            "at": Date().timeIntervalSince1970,
        ]
        writeAssignments(all)
        if surfaces[view.id] == nil { register(view) } else { evaluate(view.id) }
    }

    /// Returns the surface to rule-driven theming.
    func clearExplicitTheme(for view: Ghostty.SurfaceView) {
        var all = storedAssignments()
        all.removeValue(forKey: view.id.uuidString)
        writeAssignments(all)
        if surfaces[view.id] == nil { register(view) } else { evaluate(view.id) }
    }

    /// Creates (or replaces) a `pathPrefix` rule for the surface's current directory.
    /// - Returns: false if the surface has no known working directory.
    @discardableResult
    func addFolderRule(for view: Ghostty.SurfaceView, themeId: UUID) -> Bool {
        guard let pwd = view.pwd, !pwd.isEmpty else { return false }
        let path = ThemeRuleMatcher.standardizePath(pwd, home: home)
        let display = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        store.setPathRule(path: String(display), themeId: themeId)
        return true
    }

    /// Refreshes a pin's timestamp when its surface is seen again, so pins of long-lived
    /// (restored) surfaces never expire.
    private func touchAssignment(_ id: UUID) {
        var all = storedAssignments()
        guard var entry = all[id.uuidString] else { return }
        entry["at"] = Date().timeIntervalSince1970
        all[id.uuidString] = entry
        writeAssignments(all)
    }

    private func storedAssignments() -> [String: [String: Any]] {
        defaults.dictionary(forKey: Self.assignmentsKey) as? [String: [String: Any]] ?? [:]
    }

    /// Writes the map, dropping entries older than ``assignmentMaxAge`` that no live surface
    /// uses (closed surfaces that were never restored).
    private func writeAssignments(_ all: [String: [String: Any]]) {
        let cutoff = Date().timeIntervalSince1970 - Self.assignmentMaxAge
        let live = Set(surfaces.keys.map(\.uuidString))
        let pruned = all.filter { key, value in
            live.contains(key) || (value["at"] as? Double ?? 0) >= cutoff
        }
        defaults.set(pruned, forKey: Self.assignmentsKey)
    }
}

// MARK: - Colors

extension NSColor {
    /// `#RRGGBB` only (see `SurfaceTheme.isValidHex`), in sRGB.
    convenience init?(strictHex hex: String) {
        guard SurfaceTheme.isValidHex(hex) else { return nil }
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// `#RRGGBB` in sRGB, components clamped to 0...255 (out-of-gamut colors from the color
    /// panel can have components outside 0...1).
    var strictHexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        func byte(_ c: CGFloat) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
