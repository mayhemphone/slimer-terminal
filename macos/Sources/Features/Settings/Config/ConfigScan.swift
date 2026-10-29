import Foundation

/// Everything Settings needs to know about the config, read and parsed in one pass off the
/// main thread: the edited file (split once), Slimer's block, the user's own lines, and the
/// other files Ghostty loads that could override the block.
struct ConfigScan {
    typealias Setting = GhosttyConfigWriter.Setting
    typealias Finding = GhosttyConfigWriter.Finding

    var file: GhosttyConfigFile
    /// nil when the file couldn't be read (see `error`).
    var snapshot: GhosttyConfigFile.Snapshot?
    var lines = GhosttyConfigWriter.Lines(lines: [], hasBOM: false, newline: "\n")
    var error: String?

    /// Values of the lines Settings owns in the block.
    var managed: [String: [String]] = [:]
    /// The edited file's own settings outside the block.
    var userSettings: [Setting] = []
    /// Global bindings of the managed actions in the edited file (outside the block).
    var userBindings: [GlobalKeybindPlanner.UserBinding] = []
    /// Global bindings of the managed actions in other default files and includes.
    var otherBindings: [GlobalKeybindPlanner.UserBinding] = []
    /// Findings about the edited file, for every key Settings can manage (unfiltered).
    var findings: [Finding] = []
    /// Lines in files loaded after the edited one that set a managed key.
    var otherFindings: [Finding] = []

    /// One file Ghostty loads besides the edited one.
    struct OtherFile: Equatable {
        var url: URL
        /// Loaded after the edited file, so its lines win over the block.
        var loadsAfter: Bool
    }

    // MARK: Scanning

    static func scan(
        url: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appSupport: URL? = nil
    ) -> ConfigScan {
        let file = GhosttyConfigFile(url: url)
        var scan = ConfigScan(file: file)
        do {
            let snapshot = try file.readSnapshot()
            scan.snapshot = snapshot
            scan.lines = GhosttyConfigWriter.split(snapshot.text)
            try scan.parseMainFile()
        } catch {
            scan.error = String(describing: error)
            return scan
        }

        var others = defaultFiles(besides: url, environment: environment, appSupport: appSupport)
        others += includes(of: url, settings: scan.userSettings)
        scan.scanOtherFiles(others)
        return scan
    }

    private mutating func parseMainFile() throws {
        let entries = try GhosttyConfigWriter.managedEntries(lines: lines, owns: SettingsKeySpec.owns)
        var managed: [String: [String]] = [:]
        for entry in entries {
            // `font-family = ""` resets the list; only the names matter here.
            managed[entry.key] = entry.values.filter { !$0.isEmpty }
        }
        self.managed = managed
        let settings = try GhosttyConfigWriter.userSettings(lines: lines)
        userSettings = settings.before + settings.after
        userBindings = try GlobalKeybindPlanner.userBindings(lines: lines)
        findings = try GhosttyConfigWriter.analyze(
            lines: lines,
            keys: Set(SettingsKeySpec.orderedKeys),
            managedKeybinds: managed["keybind"] ?? [],
            keybindActions: Set(ManagedGlobalAction.allCases.map(\.rawValue))
        )
    }

    /// Reads other files (best effort; unreadable ones are skipped) and records their
    /// global bindings and the managed keys they set after the edited file.
    mutating func scanOtherFiles(_ others: [OtherFile]) {
        let managedKeybinds = managed["keybind"] ?? []
        let managedTriggers = Set(managedKeybinds.compactMap { KeybindValue(parsing: $0)?.normalizedTrigger })
        for other in others {
            guard let text = try? GhosttyConfigFile(url: other.url).readSnapshot().text else { continue }
            let path = other.url.path
            let settings = GhosttyConfigWriter.split(text).contents.enumerated().compactMap {
                GhosttyConfigWriter.parseSetting($0.element, line: $0.offset + 1)
            }
            otherBindings += GlobalKeybindPlanner.bindings(in: settings, afterBlock: true, file: path)
            guard other.loadsAfter else { continue }
            for setting in settings where SettingsKeySpec.spec(for: setting.key) != nil {
                let kind: Finding.Kind
                switch GhosttyConfigWriter.semantics(for: setting.key) {
                case .lastWins:
                    kind = .overriddenAfter
                case .appends:
                    kind = setting.value.isEmpty ? .overriddenAfter : .addsAfter
                case .keybind:
                    if setting.value == "clear" {
                        kind = .overriddenAfter
                    } else if let bind = KeybindValue(parsing: setting.value),
                              managedTriggers.contains(bind.normalizedTrigger) {
                        kind = .overriddenAfter
                    } else {
                        continue
                    }
                }
                otherFindings.append(Finding(kind: kind, key: setting.key, line: setting.line,
                                             value: setting.value, file: path))
            }
        }
    }

    // MARK: Other files

    /// Ghostty's default config files in load order: XDG `config`, XDG `config.ghostty`,
    /// Application Support `config`, Application Support `config.ghostty`.
    static func defaultFileOrder(environment: [String: String], appSupport: URL? = nil) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdgBase: URL
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            xdgBase = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            xdgBase = home.appendingPathComponent(".config", isDirectory: true)
        }
        let xdgDir = xdgBase.appendingPathComponent("ghostty", isDirectory: true)
        let appSupport = appSupport ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true))
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        return [
            xdgDir.appendingPathComponent("config"),
            xdgDir.appendingPathComponent("config.ghostty"),
            appSupport.appendingPathComponent("config"),
            appSupport.appendingPathComponent("config.ghostty"),
        ]
    }

    /// The default files other than `url`. When `url` isn't one of them (a `--config-file`
    /// override), Ghostty doesn't load the defaults, so there are none.
    static func defaultFiles(besides url: URL, environment: [String: String], appSupport: URL? = nil) -> [OtherFile] {
        let order = defaultFileOrder(environment: environment, appSupport: appSupport)
        let target = url.resolvingSymlinksInPath().path
        guard let mine = order.firstIndex(where: { $0.resolvingSymlinksInPath().path == target }) else { return [] }
        return order.enumerated().compactMap { idx, other in
            guard idx != mine, other.resolvingSymlinksInPath().path != target,
                  FileManager.default.fileExists(atPath: other.path) else { return nil }
            return OtherFile(url: other, loadsAfter: idx > mine)
        }
    }

    /// `config-file` includes of the edited file (one level, at most 8). Includes load after
    /// every default file, so they always win.
    static func includes(of url: URL, settings: [Setting]) -> [OtherFile] {
        let base = url.resolvingSymlinksInPath().deletingLastPathComponent()
        var result: [OtherFile] = []
        for setting in settings where setting.key == "config-file" && result.count < 8 {
            var path = setting.value
            if path.hasPrefix("?") { path.removeFirst() }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            guard !path.isEmpty else { continue }
            let resolved: URL
            if path.hasPrefix("~/") {
                resolved = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
            } else if path.hasPrefix("/") {
                resolved = URL(fileURLWithPath: path)
            } else {
                resolved = base.appendingPathComponent(path)
            }
            result.append(OtherFile(url: resolved, loadsAfter: true))
        }
        return result
    }
}
