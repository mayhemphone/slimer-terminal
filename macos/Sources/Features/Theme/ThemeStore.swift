import Foundation
import Combine
import OSLog

/// Owns the user's surface themes and rules, persisted to
/// `$XDG_CONFIG_HOME/slimer/themes.json` (default `~/.config/slimer/themes.json`).
///
/// - Writes are atomic.
/// - Parsing is tolerant (see ``ThemeDocument``), but the file is only ever rewritten when
///   doing so loses nothing (see ``Persistence``). A broken file is never overwritten with
///   presets; a file from a newer version, or one with entries/keys we don't understand, is
///   never rewritten at all (edits stay in memory and a warning is logged).
/// - External edits are picked up via a `DispatchSource` on the parent directory, coalesced,
///   and ignored when they decode to the state we already hold (our own writes).
///
/// All members must be used from the main thread.
final class ThemeStore: ObservableObject {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.slimer", category: "themes")

    static let shared = ThemeStore()

    @Published private(set) var themes: [SurfaceTheme]
    @Published private(set) var rules: [ThemeRule]

    /// Incremented on every change (local or external) so observers that only care that
    /// *something* changed don't have to diff.
    @Published private(set) var generation: Int = 0

    let fileURL: URL

    /// Whether in-app edits may be written back to the file.
    enum Persistence: Equatable {
        /// The file is missing or round-trips losslessly.
        case writable
        /// The file exists but isn't valid JSON. The first in-app edit moves it aside to
        /// `themes.json.broken-<timestamp>` and then writes.
        case unparseable
        /// The file can't be read (permissions, not a regular file, too large). Never written.
        case unreadable
        /// The file parsed, but rewriting it would drop data (unknown keys/kinds, invalid
        /// entries, or a newer `version`). Never written.
        case lossy
    }

    @Published private(set) var persistence: Persistence = .writable

    static let maxFileBytes = 4 * 1024 * 1024

    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private var reloadWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - fileURL: override for tests. Defaults to the XDG location.
    ///   - watch: whether to observe external changes.
    init(fileURL: URL? = nil, watch: Bool = true) {
        self.fileURL = fileURL ?? Self.defaultFileURL(environment: ProcessInfo.processInfo.environment)

        self.themes = Self.presets
        self.rules = []

        switch Self.read(fileURL: self.fileURL) {
        case .missing:
            // First run: write the presets so the user has a file to edit.
            persistence = .writable
            save()
        case .unreadable:
            persistence = .unreadable
            Self.logger.warning("themes.json is unreadable; using presets in memory and never writing")
        case .data(let data):
            if let doc = Self.decode(data) {
                themes = doc.themes
                rules = doc.rules
                persistence = Self.persistence(for: doc)
            } else {
                persistence = .unparseable
                Self.logger.warning("themes.json is not valid; using presets in memory until it is fixed or edited in-app")
            }
        }

        if watch {
            startWatching()
        }
    }

    deinit {
        stopWatching()
    }

    // MARK: Location

    /// `$XDG_CONFIG_HOME/slimer/themes.json`, falling back to `~/.config/slimer/themes.json`.
    static func defaultFileURL(environment: [String: String]) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty, xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base
            .appendingPathComponent("slimer", isDirectory: true)
            .appendingPathComponent("themes.json", isDirectory: false)
    }

    // MARK: Queries

    func theme(id: UUID?) -> SurfaceTheme? {
        guard let id else { return nil }
        return themes.first { $0.id == id }
    }

    // MARK: Mutations

    /// Inserts or replaces a theme (matched by id). Invalid colors are dropped.
    func upsert(_ theme: SurfaceTheme) {
        let clean = theme.sanitized()
        if let idx = themes.firstIndex(where: { $0.id == clean.id }) {
            themes[idx] = clean
        } else {
            themes.append(clean)
        }
        didChange()
    }

    func remove(themeId: UUID) {
        themes.removeAll { $0.id == themeId }
        rules.removeAll { $0.themeId == themeId }
        didChange()
    }

    /// Adds a rule. Rules pointing at an unknown theme are ignored.
    func add(rule: ThemeRule) {
        guard theme(id: rule.themeId) != nil else { return }
        rules.append(rule)
        didChange()
    }

    func remove(ruleId: UUID) {
        rules.removeAll { $0.id == ruleId }
        didChange()
    }

    /// Replaces any existing `pathPrefix` rule for exactly this path, then adds the new one.
    /// Used by "Always use for this folder".
    func setPathRule(path: String, themeId: UUID, priority: Int = 0) {
        guard theme(id: themeId) != nil else { return }
        rules.removeAll {
            if case .pathPrefix(let p) = $0.match { return p == path }
            return false
        }
        rules.append(ThemeRule(match: .pathPrefix(path), themeId: themeId, priority: priority))
        didChange()
    }

    private func didChange() {
        generation &+= 1
        persistUserEdit()
    }

    /// Writes after an in-app edit, according to ``persistence``.
    private func persistUserEdit() {
        switch persistence {
        case .writable:
            save()
        case .unparseable:
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("themes.json.broken-\(stamp)")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                Self.logger.warning("moved unparseable themes.json to \(backup.lastPathComponent, privacy: .public)")
                persistence = .writable
                save()
            } catch {
                Self.logger.error("could not back up unparseable themes.json; not writing: \(String(describing: error), privacy: .public)")
            }
        case .unreadable, .lossy:
            Self.logger.warning("themes.json is not safely writable; change kept in memory only")
        }
    }

    static func persistence(for doc: ThemeDocument) -> Persistence {
        if doc.version > ThemeDocument.currentVersion || doc.droppedEntries > 0 {
            logger.warning("themes.json has \(doc.droppedEntries) entries/keys this version can't preserve (file version \(doc.version)); it will not be rewritten")
            return .lossy
        }
        return .writable
    }

    // MARK: Persistence

    var document: ThemeDocument {
        ThemeDocument(themes: themes, rules: rules)
    }

    /// Re-reads the file. Does nothing if the decoded content equals the current state.
    func reload() {
        switch Self.read(fileURL: fileURL) {
        case .missing:
            // Deleted externally: keep what we have; the next edit recreates it.
            persistence = .writable
        case .unreadable:
            persistence = .unreadable
        case .data(let data):
            guard let loaded = Self.decode(data) else {
                persistence = .unparseable
                return
            }
            persistence = Self.persistence(for: loaded)
            guard loaded.themes != themes || loaded.rules != rules else { return }
            themes = loaded.themes
            rules = loaded.rules
            generation &+= 1
        }
    }

    enum ReadResult {
        case missing
        case unreadable
        case data(Data)
    }

    /// Reads the file without blocking on FIFOs/devices and with a size cap.
    static func read(fileURL: URL) -> ReadResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else { return .missing }
        guard let text = GhosttyThemeResolver.readRegularFile(fileURL, maxBytes: maxFileBytes) else {
            return .unreadable
        }
        return .data(Data(text.utf8))
    }

    static func load(from url: URL) -> ThemeDocument? {
        guard case .data(let data) = read(fileURL: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> ThemeDocument? {
        do {
            var doc = try JSONDecoder().decode(ThemeDocument.self, from: data)
            doc.droppedEntries += ThemeDocument.unknownKeyCount(in: data)
            return doc
        } catch {
            logger.warning("themes.json could not be parsed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func encode(_ document: ThemeDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try Self.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("failed to write themes.json: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Watching

    /// Watches the parent directory rather than the file: atomic writes replace the inode,
    /// which would silently detach a per-file source.
    private func startWatching() {
        let dir = fileURL.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        directoryDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        directorySource = source
    }

    private func stopWatching() {
        directorySource?.cancel()
        directorySource = nil
        directoryDescriptor = -1
    }

    /// Coalesce bursts of directory events (editors write several times) into one reload.
    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: item)
    }

    // MARK: Presets

    /// Stable ids so rules written on one machine resolve on another.
    private static func presetId(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5A11AE00-0000-4000-8000-%012X", n))!
    }

    static let presets: [SurfaceTheme] = [
        SurfaceTheme(id: presetId(1), name: "Slimer Green",
                     background: "#0B1A12", foreground: "#D7F5DC",
                     cursorColor: "#5CF28A", selectionBackground: "#1E4D32", accent: "#3DDC84"),
        SurfaceTheme(id: presetId(2), name: "Ocean",
                     background: "#0B1622", foreground: "#D6E6F2",
                     cursorColor: "#5FB3F6", selectionBackground: "#1C3A55", accent: "#3B9DE1"),
        SurfaceTheme(id: presetId(3), name: "Ember",
                     background: "#1C100C", foreground: "#F6E3D6",
                     cursorColor: "#FF8A4C", selectionBackground: "#5A2C1A", accent: "#F26B3A"),
        SurfaceTheme(id: presetId(4), name: "Graphite",
                     background: "#161718", foreground: "#DCDCDC",
                     cursorColor: "#BDBDBD", selectionBackground: "#3A3D40", accent: "#8E8E93"),
        SurfaceTheme(id: presetId(5), name: "Plum",
                     background: "#190F1F", foreground: "#EBDDF2",
                     cursorColor: "#C77DFF", selectionBackground: "#4A2A5C", accent: "#AF52DE"),
        SurfaceTheme(id: presetId(6), name: "Sand",
                     background: "#F5EEDC", foreground: "#3B3222",
                     cursorColor: "#B5802B", selectionBackground: "#E3D3A8", accent: "#C8963E"),
        SurfaceTheme(id: presetId(7), name: "Rose",
                     background: "#1F1014", foreground: "#F7DEE5",
                     cursorColor: "#FF6B9D", selectionBackground: "#5C2A3B", accent: "#F2557F"),
        SurfaceTheme(id: presetId(8), name: "Midnight",
                     background: "#070A14", foreground: "#C9D1E6",
                     cursorColor: "#7C8CFF", selectionBackground: "#1D2545", accent: "#5E6AD2"),
    ]
}
