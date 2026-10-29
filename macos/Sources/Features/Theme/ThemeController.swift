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
            .sink { [weak self] _ in self?.reevaluateAll() }
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

        view.$pwd
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate(id) }
            .store(in: &state.cancellables)

        view.$title
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
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
            return store.theme(id: themeId)
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

        ThemeApplier.apply(theme: desired, to: view, app: app)
        state.applied = desired
        pushAccent(for: id, force: false)
        NotificationCenter.default.post(name: .slimerSurfaceThemeDidChange, object: view)
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
        if !force, let focused = window.terminalController?.focusedSurface, focused !== view { return }
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
}
