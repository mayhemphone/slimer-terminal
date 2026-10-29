import AppKit
import Combine
import GhosttyKit
import OSLog

/// The Settings window's view of the Ghostty config: what Slimer's managed block holds,
/// what the user's own lines (and other config files) say, and what Ghostty loaded.
///
/// - Reading and parsing happen on a background queue (``ConfigScan``); published state is
///   only changed on the main thread.
/// - Edits are validated, collected, and written 300 ms after the last change (so a slider
///   doesn't rewrite the file on every tick), also off the main thread. Pending edits are
///   flushed when the window closes and when the app quits.
/// - Each write re-reads the file, rewrites only Settings' own lines in the block, refuses
///   to recreate a file that disappeared (an editor mid-save), writes atomically and aborts
///   if the file changed underneath (retrying once), then reloads the config. When the
///   reloaded config arrives, every written key Ghostty can report is compared with what was
///   written; keys that didn't apply get a badge.
@MainActor
final class SettingsConfigStore: ObservableObject {
    typealias Finding = GhosttyConfigWriter.Finding
    typealias UserBinding = GlobalKeybindPlanner.UserBinding

    nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.slimer", category: "settings")

    static let writeDebounce: TimeInterval = 0.3

    /// Keys whose effective value can't be read back through the C API.
    static let unverifiableKeys: Set<String> = ["theme", "font-family", "keybind"]

    /// The file being edited, or nil before ``load(url:synchronously:)``.
    @Published private(set) var file: GhosttyConfigFile?
    /// Desired managed values (canonical text), keyed by Ghostty key.
    @Published private(set) var managed: [String: [String]] = [:]
    /// The user's own settings outside the block, for showing current values.
    @Published private(set) var userSettings: [GhosttyConfigWriter.Setting] = []
    /// Notes about the edited file's lines (overrides after the block, includes, …).
    @Published private(set) var findings: [Finding] = []
    /// Lines in other files loaded after the edited one that set a managed key.
    @Published private(set) var otherFindings: [Finding] = []
    /// Per-action state of the managed global hotkeys.
    @Published private(set) var globalKeybinds: [ManagedGlobalAction: GlobalKeybindState] = [:]
    /// The user's own global bindings for the managed actions (edited file).
    @Published private(set) var userGlobalBindings: [UserBinding] = []
    /// Global bindings for the managed actions in other default files and includes.
    @Published private(set) var otherGlobalBindings: [UserBinding] = []
    /// Bindings Settings can't unbind (outside the recorder grammar, after the block, or in
    /// another file).
    @Published private(set) var leftActiveBindings: [UserBinding] = []
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
    private var observers: [NSObjectProtocol] = []
    /// Whether the file existed when it was last read; if it did, a write never recreates it.
    private var fileExisted = false
    private var rawFindings: [Finding] = []
    private var loadGeneration = 0
    private let ioQueue = DispatchQueue(label: "top.mayhem.slimer.settings-io", qos: .userInitiated)

    /// Overrides the config path (tests). Production re-resolves it on every load.
    var explicitURL: URL?
    /// The environment used to find Ghostty's default files (tests point it at a temp dir).
    var environment: [String: String] = ProcessInfo.processInfo.environment
    /// Ghostty's Application Support directory (`…/com.mitchellh.ghostty`); nil = the
    /// user's. Tests point it at a temp dir.
    var appSupportDirectory: URL?

    /// Injected for tests; defaults to the app's reload.
    var reloadConfig: () -> Void = {
        (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
    }

    /// The config Ghostty is using right now.
    var currentConfig: () -> Ghostty.Config? = {
        (NSApp.delegate as? AppDelegate)?.ghostty.config
    }

    static let shared = SettingsConfigStore()

    /// - Parameter terminationNotification: posted when the app quits; pending edits are
    ///   flushed then. Tests pass their own name.
    init(terminationNotification: Notification.Name = NSApplication.willTerminateNotification) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .ghosttyConfigDidChange, object: nil, queue: .main) { [weak self] notification in
            // Only app-level changes (object nil); surface-level ones are per-terminal.
            guard notification.object == nil,
                  let config = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config
            else { return }
            MainActor.assumeIsolated { self?.configDidReload(config) }
        })
        observers.append(center.addObserver(forName: terminationNotification, object: nil, queue: .main) { [weak self] _ in
            // Don't lose an edit made less than the debounce interval before quitting.
            MainActor.assumeIsolated { self?.flush() }
        })
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

    /// Re-resolves the config path, then reads and parses the files off the main thread.
    /// Called when the window opens or becomes key, and after each write.
    func load(url: URL? = nil, synchronously: Bool = false) {
        if let url { explicitURL = url }
        guard let target = explicitURL ?? Self.resolveConfigURL() else {
            fileError = "Couldn't find the Ghostty config file."
            return
        }
        if let config = currentConfig() {
            diagnostics = config.errors
        }
        loadGeneration += 1
        let generation = loadGeneration
        let environment = self.environment
        let appSupport = appSupportDirectory
        if synchronously {
            apply(ioQueue.sync { ConfigScan.scan(url: target, environment: environment, appSupport: appSupport) })
            return
        }
        ioQueue.async { [weak self] in
            let scan = ConfigScan.scan(url: target, environment: environment, appSupport: appSupport)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.loadGeneration else { return }
                    self.apply(scan)
                }
            }
        }
    }

    private func apply(_ scan: ConfigScan) {
        file = scan.file
        if let error = scan.error {
            fileError = error
            return
        }
        fileError = nil
        fileExisted = scan.snapshot?.stamp != nil
        userSettings = scan.userSettings
        userGlobalBindings = scan.userBindings
        otherGlobalBindings = scan.otherBindings
        otherFindings = scan.otherFindings
        rawFindings = scan.findings
        // Edits still waiting for the debounce win over what's on disk.
        if !hasPendingWrite {
            managed = scan.managed
            globalKeybinds = GlobalKeybindPlanner.states(
                managedValues: managed["keybind"] ?? [],
                userBindings: userGlobalBindings
            )
            reconcileKeybinds()
        }
        recomputeDerived()
    }

    /// The block's keybinds must match what the planner would write for the current user
    /// lines. If the user removed a line Slimer unbinds, the stale `global:<t>=unbind` would
    /// remove an unrelated later binding on that trigger, so the block is rewritten.
    private func reconcileKeybinds() {
        let plan = GlobalKeybindPlanner.plan(states: globalKeybinds, userBindings: userGlobalBindings)
        let current = managed["keybind"] ?? []
        guard plan.values != current else { return }
        Self.logger.info("rewriting Slimer's keybinds to match the current config")
        setManagedKeybinds(plan.values)
        globalKeybinds = GlobalKeybindPlanner.states(managedValues: plan.values, userBindings: userGlobalBindings)
        scheduleWrite()
    }

    private func setManagedKeybinds(_ values: [String]) {
        if values.isEmpty {
            managed.removeValue(forKey: "keybind")
        } else {
            managed["keybind"] = values
        }
    }

    private func recomputeDerived() {
        // "Set before the block" only matters for keys the block overrides.
        let managedKeys = Set(managed.keys)
        findings = rawFindings.filter { $0.kind != .setBefore || managedKeys.contains($0.key) }
        leftActiveBindings = GlobalKeybindPlanner.plan(
            states: globalKeybinds,
            userBindings: userGlobalBindings + otherGlobalBindings
        ).leftActive
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

    /// Findings that concern `key`, in this file and in files loaded after it.
    func findings(for key: String) -> [Finding] {
        (findings + otherFindings).filter { $0.key == key }
    }

    /// The key is overridden by a later line, so editing it is pointless.
    func isOverridden(_ key: String) -> Bool {
        findings(for: key).contains { $0.kind == .overriddenAfter }
    }

    /// `config-file` includes of the edited file.
    var includeFindings: [Finding] { findings.filter { $0.kind == .include } }

    /// A line too long for Ghostty before the block, if any.
    var longLineFinding: Finding? { findings.first { $0.kind == .longLine } }

    /// What to say about includes under `key`'s control, if the file has any.
    func includeNote(for key: String) -> (text: String, isWarning: Bool)? {
        guard !includeFindings.isEmpty else { return nil }
        let names = includeFindings.map { "“\($0.value)”" }.joined(separator: ", ")
        if Self.unverifiableKeys.contains(key) {
            return ("Your config includes \(names), which load after it and could override this; Settings can't check \(key) after a reload.", true)
        }
        return ("Your config includes \(names), which load after it and win. If this doesn't apply, look there.", false)
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
            recomputeDerived()
            scheduleWrite()
            return
        }
        switch SettingsValidator.validate(key: key, value: value) {
        case .success(let canonical):
            fieldErrors[key] = nil
            guard managed[key] != [canonical] else { return }
            managed[key] = [canonical]
            recomputeDerived()
            scheduleWrite()
        case .failure(let error):
            fieldErrors[key] = error.description
        }
    }

    func setGlobalKeybind(_ action: ManagedGlobalAction, _ state: GlobalKeybindState) {
        if case .set(let trigger) = state, let error = KeyTrigger.globalHotkeyError(trigger) {
            fieldErrors["keybind"] = error
            return
        }
        fieldErrors["keybind"] = nil
        globalKeybinds[action] = state
        let plan = GlobalKeybindPlanner.plan(states: globalKeybinds, userBindings: userGlobalBindings)
        setManagedKeybinds(plan.values)
        recomputeDerived()
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
            MainActor.assumeIsolated { self?.flushInBackground() }
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

    /// Writes pending edits now and waits for the write (window close, app quit, tests).
    func flush() {
        guard let job = takePendingJob() else { return }
        let outcome = ioQueue.sync { Self.performWrite(job) }
        finishWrite(outcome, synchronously: true)
    }

    /// The debounced path: the write happens on the I/O queue.
    private func flushInBackground() {
        guard let job = takePendingJob() else { return }
        ioQueue.async {
            let outcome = Self.performWrite(job)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in self?.finishWrite(outcome, synchronously: false) }
            }
        }
    }

    struct WriteJob {
        var file: GhosttyConfigFile
        var entries: [GhosttyConfigWriter.Entry]
        var fileExisted: Bool
    }

    struct WriteOutcome: Equatable {
        var wrote = false
        var error: String?
    }

    private func takePendingJob() -> WriteJob? {
        pendingWrite?.cancel()
        pendingWrite = nil
        guard hasPendingWrite else { return nil }
        hasPendingWrite = false
        guard let file else { return nil }
        awaitingVerification = managed
        return WriteJob(file: file, entries: entries(), fileExisted: fileExisted)
    }

    /// Re-reads, renders and writes. Retries once if the file changes between the read and
    /// the rename. Never recreates a file that existed when Settings last read it.
    nonisolated static func performWrite(_ job: WriteJob) -> WriteOutcome {
        for attempt in 0 ..< 2 {
            do {
                let snapshot = try job.file.readSnapshot()
                if snapshot.stamp == nil && job.fileExisted {
                    throw GhosttyConfigFile.FileError.vanished(job.file.targetURL.path)
                }
                let lines = GhosttyConfigWriter.split(snapshot.text)
                let rendered = try GhosttyConfigWriter.render(lines: lines, entries: job.entries, owns: SettingsKeySpec.owns)
                guard rendered != snapshot.text else { return WriteOutcome() }
                let addsBlock = try GhosttyConfigWriter.blockRange(in: lines.contents) == nil
                try job.file.write(rendered, expected: snapshot.stamp, backup: addsBlock)
                return WriteOutcome(wrote: true)
            } catch GhosttyConfigFile.FileError.changedOnDisk(_) where attempt == 0 {
                continue
            } catch {
                logger.error("config write failed: \(String(describing: error), privacy: .public)")
                return WriteOutcome(error: String(describing: error))
            }
        }
        return WriteOutcome(error: "The config kept changing while Settings was saving; nothing was written.")
    }

    private func finishWrite(_ outcome: WriteOutcome, synchronously: Bool) {
        if let error = outcome.error {
            fileError = error
            awaitingVerification = nil
            return
        }
        fileError = nil
        if outcome.wrote {
            lastWrite = Date()
            reloadConfig()
        } else {
            awaitingVerification = nil
        }
        load(synchronously: synchronously)
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
