import AppKit
import Combine
import GhosttyKit
import OSLog

/// The Settings window's view of the Ghostty config: what Slimer's managed block holds,
/// what the user's own lines say, and what Ghostty actually loaded.
///
/// Edits are validated, collected, and written 300 ms after the last change (so a slider
/// doesn't rewrite the file on every tick). Each write re-reads the file, replaces only the
/// managed block, writes atomically, then reloads the config. When the reloaded config
/// arrives, every written key Ghostty can report is compared with what was written; keys
/// that didn't apply get a badge.
@MainActor
final class SettingsConfigStore: ObservableObject {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.slimer", category: "settings")

    static let writeDebounce: TimeInterval = 0.3

    /// The file being edited, or nil before ``load()``.
    @Published private(set) var file: GhosttyConfigFile?
    /// Desired managed values (canonical text), keyed by Ghostty key.
    @Published private(set) var managed: [String: [String]] = [:]
    /// The user's own settings outside the block, for showing current values.
    @Published private(set) var userSettings: [GhosttyConfigWriter.Setting] = []
    /// Notes about the user's lines (overrides after the block, includes, …).
    @Published private(set) var findings: [GhosttyConfigWriter.Finding] = []
    /// Per-action state of the managed global hotkeys.
    @Published private(set) var globalKeybinds: [ManagedGlobalAction: GlobalKeybindState] = [:]
    /// The user's own global bindings for the managed actions.
    @Published private(set) var userGlobalBindings: [GlobalKeybindPlanner.UserBinding] = []
    /// User bindings Settings can't unbind (outside the recorder grammar or after the block).
    @Published private(set) var leftActiveBindings: [GlobalKeybindPlanner.UserBinding] = []
    /// A read, write or block error. While set for a malformed block, nothing is written.
    @Published private(set) var fileError: String?
    /// Validation errors from the last edit, per key.
    @Published private(set) var fieldErrors: [String: String] = [:]
    /// Keys whose written value Ghostty didn't load, with what it loaded instead.
    @Published private(set) var notApplied: [String: String] = [:]
    /// Ghostty's diagnostics from the most recent load.
    @Published private(set) var diagnostics: [String] = []
    /// True while a write is waiting for the debounce.
    @Published private(set) var hasPendingWrite = false
    /// When the last write finished.
    @Published private(set) var lastWrite: Date?

    private var pendingWrite: DispatchWorkItem?
    private var awaitingVerification: [String: [String]]?
    private var configObserver: NSObjectProtocol?

    /// Injected for tests; defaults to the app's reload.
    var reloadConfig: () -> Void = {
        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
    }

    /// The config Ghostty is using right now.
    var currentConfig: () -> Ghostty.Config? = {
        (NSApp.delegate as? AppDelegate)?.ghostty.config
    }

    static let shared = SettingsConfigStore()

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Only app-level changes (object nil); surface-level ones are per-terminal.
            guard notification.object == nil,
                  let config = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config
            else { return }
            MainActor.assumeIsolated {
                self?.configDidReload(config)
            }
        }
    }

    // MARK: - Path

    /// The path "Open Config" uses: the app's `--config-file` override if any, otherwise
    /// libghostty's `ghostty_config_open_path` (creates the file if needed).
    static func resolveConfigURL() -> URL? {
        if let override = (NSApp.delegate as? AppDelegate)?.ghostty.configPath, !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let path = Ghostty.AllocatedString(ghostty_config_open_path()).string
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Loading

    /// Reads the file and Ghostty's state. Cheap; called when the window opens and after
    /// each write.
    func load(url: URL? = nil) {
        if file == nil || url != nil {
            guard let resolved = url ?? Self.resolveConfigURL() else {
                fileError = "Couldn't find the Ghostty config file."
                return
            }
            file = GhosttyConfigFile(url: resolved)
        }
        guard let file else { return }

        do {
            let text = try file.read()
            try refresh(from: text)
            fileError = nil
        } catch {
            fileError = String(describing: error)
        }
        if let config = currentConfig() {
            diagnostics = config.errors
        }
    }

    private func refresh(from text: String) throws {
        let entries = try GhosttyConfigWriter.managedEntries(in: text)
        var managed: [String: [String]] = [:]
        for entry in entries {
            // `font-family = ""` resets the list; only the names matter here.
            managed[entry.key] = entry.values.filter { !$0.isEmpty }
        }
        let settings = try GhosttyConfigWriter.userSettings(in: text)
        let bindings = try GlobalKeybindPlanner.userBindings(in: text)
        self.userSettings = settings.before + settings.after
        self.userGlobalBindings = bindings
        // Edits still waiting for the debounce win over what's on disk.
        if !hasPendingWrite {
            self.managed = managed
            self.globalKeybinds = GlobalKeybindPlanner.states(
                managedValues: managed["keybind"] ?? [],
                userBindings: bindings
            )
        }
        // Every key Settings can manage is checked, so a control can warn before the first
        // edit. "Set before the block" is only worth saying for keys the block overrides.
        let managedKeys = Set(self.managed.keys)
        self.findings = try GhosttyConfigWriter.analyze(
            text: text,
            keys: Set(SettingsKeySpec.orderedKeys),
            managedKeybinds: self.managed["keybind"] ?? [],
            keybindActions: Set(ManagedGlobalAction.allCases.map(\.rawValue))
        ).filter { $0.kind != .setBefore || managedKeys.contains($0.key) }
        self.leftActiveBindings = GlobalKeybindPlanner.plan(states: globalKeybinds, userBindings: bindings).leftActive
    }

    // MARK: - Reading values

    /// The value Settings should show for `key`: the managed value, else Ghostty's
    /// effective value, else the user's last line for it.
    func displayValue(for key: String) -> String? {
        if let values = managed[key], let last = values.last { return last }
        if let config = currentConfig(), let value = EffectiveConfigReader.value(for: key, in: config) {
            return value
        }
        return userSettings.last { $0.key == key && !$0.value.isEmpty }?.value
    }

    func isManaged(_ key: String) -> Bool { managed[key] != nil }

    /// Findings that concern `key`.
    func findings(for key: String) -> [GhosttyConfigWriter.Finding] {
        findings.filter { $0.key == key }
    }

    /// The key is overridden by a user line after the block, so editing it is pointless.
    func isOverridden(_ key: String) -> Bool {
        findings.contains { $0.key == key && $0.kind == .overriddenAfter }
    }

    // MARK: - Editing

    /// Sets (or with nil, stops managing) `key`. Invalid values are rejected and reported
    /// in ``fieldErrors``; nothing is scheduled for them.
    func set(_ key: String, _ value: String?) {
        guard key != "keybind" else { return }
        guard let value else {
            fieldErrors[key] = nil
            guard managed[key] != nil else { return }
            managed.removeValue(forKey: key)
            scheduleWrite()
            return
        }
        switch SettingsValidator.validate(key: key, value: value) {
        case .success(let canonical):
            fieldErrors[key] = nil
            guard managed[key] != [canonical] else { return }
            managed[key] = [canonical]
            scheduleWrite()
        case .failure(let error):
            fieldErrors[key] = error.description
        }
    }

    func setGlobalKeybind(_ action: ManagedGlobalAction, _ state: GlobalKeybindState) {
        if case .set(let trigger) = state, !KeyTrigger.isValid(trigger, requireModifier: true) {
            fieldErrors["keybind"] = "\(KeyTrigger.displayString(trigger)) can't be a global hotkey; add a modifier."
            return
        }
        fieldErrors["keybind"] = nil
        globalKeybinds[action] = state
        let plan = GlobalKeybindPlanner.plan(states: globalKeybinds, userBindings: userGlobalBindings)
        leftActiveBindings = plan.leftActive
        if plan.values.isEmpty {
            managed.removeValue(forKey: "keybind")
        } else {
            managed["keybind"] = plan.values
        }
        scheduleWrite()
    }

    /// The trigger the user sees for `action`: Settings' own, else their last global line.
    func effectiveTrigger(for action: ManagedGlobalAction) -> (trigger: String?, fromUserLine: Int?) {
        switch globalKeybinds[action] ?? .unmanaged {
        case .set(let trigger): return (trigger, nil)
        case .disabled: return (nil, nil)
        case .unmanaged:
            guard let binding = userGlobalBindings.last(where: { $0.action == action }) else { return (nil, nil) }
            return (binding.trigger, binding.line)
        }
    }

    // MARK: - Writing

    private func scheduleWrite() {
        pendingWrite?.cancel()
        hasPendingWrite = true
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDebounce, execute: work)
    }

    /// The managed entries in registry order, ready for the writer.
    func entries() -> [GhosttyConfigWriter.Entry] {
        SettingsKeySpec.orderedKeys.compactMap { key in
            guard let values = managed[key], !values.isEmpty else { return nil }
            if key == "font-family" {
                // Reset first so the name replaces earlier lines instead of adding a fallback.
                return GhosttyConfigWriter.Entry(key, ["\"\""] + values)
            }
            return GhosttyConfigWriter.Entry(key, values)
        }
    }

    /// Writes pending edits now (also called when the window closes).
    func flush() {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard hasPendingWrite else { return }
        hasPendingWrite = false
        guard let file else { return }

        let current: String
        let rendered: String
        do {
            // Always start from what's on disk now, so concurrent hand edits survive.
            current = try file.read()
            rendered = try GhosttyConfigWriter.render(text: current, entries: entries())
        } catch {
            fileError = String(describing: error)
            Self.logger.error("not writing config: \(String(describing: error), privacy: .public)")
            return
        }

        if rendered != current {
            do {
                let firstWrite = (try? GhosttyConfigWriter.blockRange(in: GhosttyConfigWriter.split(current).lines)) == nil
                try file.write(rendered, backup: firstWrite)
                lastWrite = Date()
                fileError = nil
            } catch {
                fileError = String(describing: error)
                Self.logger.error("config write failed: \(String(describing: error), privacy: .public)")
                return
            }
        }

        try? refresh(from: rendered)
        awaitingVerification = managed
        reloadConfig()
    }

    // MARK: - Verification

    private func configDidReload(_ config: Ghostty.Config) {
        diagnostics = config.errors
        guard let expected = awaitingVerification else { return }
        awaitingVerification = nil
        var missing: [String: String] = [:]
        for (key, values) in expected {
            guard let written = values.last,
                  let effective = EffectiveConfigReader.value(for: key, in: config) else { continue }
            if !EffectiveConfigReader.matches(key: key, written: written, effective: effective) {
                missing[key] = effective
            }
        }
        notApplied = missing
    }
}
