import AppKit
import Combine
import OSLog

/// Owns `~/.config/slimer/workspace.json` (synced between machines) and this
/// machine's `recent.json` and `usage.json` (see `WorkspacePath.localDirectory`):
/// loads them, saves them atomically, watches workspace.json for external
/// changes (dotfile sync, hand edits) and records usage. One instance is
/// owned by `AppDelegate`; use `WorkspaceStore.shared` from UI code.
///
/// workspace.json is only written when the user edits locations or commands
/// (Settings) or on first run; usage and visits go to the local files. It is
/// never written while it cannot be parsed, or when it comes from a newer
/// Slimer (`version` above `WorkspaceDocument.currentVersion`).
///
/// All members must be used on the main thread (like the rest of the app's
/// controllers; not actor-annotated because `AppDelegate` creates it from a
/// non-isolated property initializer).
final class WorkspaceStore: ObservableObject {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.slimer",
        category: "workspace"
    )

    /// The current document. Replaced wholesale on reload.
    @Published private(set) var document: WorkspaceDocument

    /// This machine's recent directories (`recent.json`).
    @Published private(set) var recent: WorkspaceRecentDocument

    /// This machine's usage statistics (`usage.json`).
    @Published private(set) var usage: WorkspaceUsageDocument

    /// Set when the file on disk could not be parsed. While set we keep the
    /// in-memory document and never overwrite the file, so a hand edit with a
    /// typo is not clobbered.
    @Published private(set) var loadError: String?

    /// Where the document lives (may be a symlink into a dotfiles repo).
    let fileURL: URL
    /// This machine's recent directories.
    let recentFileURL: URL
    /// This machine's usage statistics.
    let usageFileURL: URL

    private let now: () -> Date
    private let visitDebounce: TimeInterval
    /// The bytes we last read from or successfully wrote to disk. Anything
    /// else on disk is an external edit.
    private var lastWrittenData: Data?
    private var watcher: WorkspaceFileWatcher?
    private var pendingVisit: DispatchWorkItem?
    private var visitGeneration = 0
    private var lastCommittedVisit: (path: String, date: Date)?
    /// Whether `recent.json` exists (so the one-time migration is done).
    private var recentFileExists: Bool

    /// Queue for `stat` calls on shell-reported (untrusted) paths so a slow
    /// or hung filesystem never blocks the main thread.
    private static let statQueue = DispatchQueue(label: "slimer.workspace.stat", qos: .utility)

    /// - Parameters:
    ///   - fileURL: the JSON file. Defaults to the XDG-aware location (a temp
    ///     file under XCTest).
    ///   - localDirectory: where `recent.json` and `usage.json` live.
    ///     Defaults to `WorkspacePath.localDirectory()` (a temp directory
    ///     under XCTest).
    ///   - watch: whether to reload when the file changes on disk. Off by
    ///     default under XCTest.
    ///   - visitDebounce: how long a directory must stay current before it
    ///     counts as a visit.
    ///   - now: clock, injectable for tests.
    init(
        fileURL: URL = WorkspacePath.defaultFileURL(),
        localDirectory: URL = WorkspacePath.localDirectory(),
        watch: Bool = !WorkspacePath.isRunningUnderXCTest(),
        visitDebounce: TimeInterval = 1.5,
        now: @escaping () -> Date = Date.init
    ) {
        let recentFileURL = localDirectory.appendingPathComponent("recent.json", isDirectory: false)
        let usageFileURL = localDirectory.appendingPathComponent("usage.json", isDirectory: false)
        self.fileURL = fileURL
        self.recentFileURL = recentFileURL
        self.usageFileURL = usageFileURL
        self.now = now
        self.visitDebounce = visitDebounce
        self.document = WorkspaceDocument()
        self.recent = Self.readLocal(recentFileURL, WorkspaceRecentDocument.init(json:)) ?? WorkspaceRecentDocument()
        self.usage = Self.readLocal(usageFileURL, WorkspaceUsageDocument.init(json:)) ?? WorkspaceUsageDocument()
        self.recentFileExists = FileManager.default.fileExists(atPath: recentFileURL.path)

        switch Self.read(fileURL) {
        case .missing:
            document = .seed()
            writeCurrentDocument()
            Self.logger.info("seeded \(fileURL.path, privacy: .public)")
        case .loaded(let doc, let data):
            adopt(doc, data: data)
        case .invalid(let message):
            loadError = message
            Self.logger.error("workspace.json could not be read, keeping defaults in memory: \(message, privacy: .public)")
        }

        if watch {
            // The watcher delivers on the main queue.
            watcher = WorkspaceFileWatcher(fileURL: fileURL) { [weak self] in
                self?.reloadFromDisk(force: false)
            }
        }
    }

    // MARK: - Public API

    /// Re-read the file from disk even if it looks unchanged. Recreates the
    /// seed file if it is missing.
    func reload() {
        reloadFromDisk(force: true)
    }

    /// Open the JSON file in the default editor. Creates it first if missing.
    func openInEditor() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            loadError = nil
            writeCurrentDocument()
        }
        NSWorkspace.shared.open(fileURL)
    }

    /// Whether edits are saved. While the file on disk is invalid they would stay in memory
    /// only, and a file from a newer Slimer is never rewritten (this version could drop what
    /// it doesn't understand), so Settings disables editing.
    var acceptsEdits: Bool { loadError == nil && !document.isNewerVersion }

    /// Apply an edit from Settings (add, change, delete, reorder). A newer file on disk is
    /// loaded first and the edit re-applied on top. Ignored for a file from a newer Slimer.
    func edit(_ change: (inout WorkspaceDocument) -> Void) {
        mutate(change)
    }

    /// Visible locations (usable on this OS), pinned first, then by frecency.
    func rankedLocations(now: Date = Date()) -> [WorkspaceLocation] {
        document.rankedLocations(usage: usage, now: now)
    }

    /// Visible commands (usable on this OS), pinned first, then by frecency.
    func rankedCommands(now: Date = Date()) -> [WorkspaceCommand] {
        document.rankedCommands(usage: usage, now: now)
    }

    /// This machine's recent directories by frecency.
    func rankedRecent(now: Date = Date()) -> [WorkspaceRecentDirectory] {
        recent.rankedRecent(now: now)
    }

    /// Forget this machine's recent directories.
    func clearRecent() {
        recent = WorkspaceRecentDocument()
        writeRecent()
    }

    /// Count a use of a location (also counts a visit to its directory).
    /// Stored in this machine's files; workspace.json is not written.
    func recordUse(location: WorkspaceLocation) {
        guard let current = document.locations.first(where: { $0.id == location.id }) else { return }
        let date = now()
        usage.recordUse(id: current.id, seed: current.legacyUsage, now: date)
        writeUsage()

        let path = current.expandedPath
        if WorkspacePath.isRecordable(path) {
            // The shell will report this directory right after the cd; don't
            // count it twice.
            lastCommittedVisit = (path, date)
            recent.recordVisit(path: path, now: date)
            writeRecent()
        }
    }

    /// Count a use of a saved command. Stored in this machine's files.
    func recordUse(command: WorkspaceCommand) {
        guard let current = document.commands.first(where: { $0.id == command.id }) else { return }
        usage.recordUse(id: current.id, seed: current.legacyUsage, now: now())
        writeUsage()
    }

    /// Called whenever a terminal's working directory changes. Only reports
    /// from the key window count. The path is shell-reported (untrusted), so
    /// it is filtered with cheap string checks here, the existence check runs
    /// off the main thread after `visitDebounce`, and the visit is committed
    /// back on the main thread if nothing newer arrived meanwhile.
    func recordVisit(_ url: URL?, window: NSWindow?) {
        guard window?.isKeyWindow == true else { return }
        recordVisit(url)
    }

    /// See `recordVisit(_:window:)`; this variant skips the key-window check.
    func recordVisit(_ url: URL?) {
        pendingVisit?.cancel()
        pendingVisit = nil
        visitGeneration += 1
        guard let url, url.isFileURL else { return }
        let path = WorkspacePath.expand(url.path)
        guard WorkspacePath.isRecordable(path) else { return }

        let generation = visitGeneration
        let work = DispatchWorkItem { [weak self] in
            Self.statQueue.async {
                let exists = Self.directoryExists(path)
                DispatchQueue.main.async {
                    guard let self, exists, generation == self.visitGeneration else { return }
                    self.commitVisit(path)
                }
            }
        }
        pendingVisit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, visitDebounce), execute: work)
    }

    /// Commit a visit to a path already verified to exist. Repeat visits to
    /// the same directory within a minute are counted once.
    func commitVisit(_ path: String) {
        pendingVisit = nil
        guard WorkspacePath.isRecordable(path) else { return }
        let date = now()
        if let last = lastCommittedVisit,
           last.path == path,
           date.timeIntervalSince(last.date) < 60 {
            return
        }
        lastCommittedVisit = (path, date)
        recent.recordVisit(path: path, now: date)
        writeRecent()
    }

    /// Whether `path` is an existing directory. Blocking; never call on main
    /// for untrusted paths.
    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Disk

    enum ReadResult {
        case missing
        case loaded(WorkspaceDocument, Data)
        case invalid(String)
    }

    static func read(_ url: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .invalid("read failed: \(error.localizedDescription)")
        }
        do {
            return .loaded(try WorkspaceDocument.decode(data), data)
        } catch {
            return .invalid("parse failed: \(error)")
        }
    }

    private func reloadFromDisk(force: Bool) {
        switch Self.read(fileURL) {
        case .missing:
            // Sync tools may delete and recreate; only reseed on an explicit reload.
            guard force else { return }
            loadError = nil
            document = .seed()
            lastWrittenData = nil
            writeCurrentDocument()
        case .loaded(let doc, let data):
            loadError = nil
            if !force, data == lastWrittenData { return }
            adopt(doc, data: data)
        case .invalid(let message):
            loadError = message
            Self.logger.error("workspace.json reload failed: \(message, privacy: .public)")
        }
    }

    /// Take a document read from disk. Logged once per distinct file
    /// content: entries this version can't use, and a newer `version`.
    private func adopt(_ doc: WorkspaceDocument, data: Data) {
        lastWrittenData = data
        if doc != document { document = doc }
        if doc.unusableCount > 0 {
            Self.logger.warning("workspace.json has \(doc.unusableCount) entries this version can't use; they are kept in the file but not shown")
        }
        if doc.isNewerVersion {
            Self.logger.warning("workspace.json is version \(doc.version), newer than \(WorkspaceDocument.currentVersion); it is shown read-only and never written")
        }
        migrateRecentIfNeeded()
    }

    /// One-time move of this machine's entries from the legacy `recent`
    /// array in workspace.json into `recent.json`. The array itself stays in
    /// workspace.json untouched (it may hold other machines' entries).
    private func migrateRecentIfNeeded() {
        guard !recentFileExists, document.raw.unknown["recent"] != nil else { return }
        let migrated = WorkspaceRecentDocument.migrated(from: document.legacyRecent)
        for entry in migrated.recent where !recent.recent.contains(where: { $0.path == entry.path }) {
            recent.recent.append(entry)
        }
        writeRecent()
        Self.logger.info("migrated \(migrated.recent.count) recent directories to \(self.recentFileURL.path, privacy: .public)")
    }

    /// Apply a change and persist it. If the file changed on disk since we
    /// last read or wrote it (an edit the watcher has not delivered yet), the
    /// disk version is loaded first and the change is re-applied on top, so
    /// external edits are never overwritten. While the file is invalid the
    /// change stays in memory only; a file from a newer version is not
    /// changed at all.
    private func mutate(_ change: (inout WorkspaceDocument) -> Void) {
        if loadError == nil {
            switch Self.read(fileURL) {
            case .loaded(let disk, let data) where data != lastWrittenData:
                adopt(disk, data: data)
            case .invalid(let message):
                loadError = message
                Self.logger.error("workspace.json became invalid; keeping changes in memory: \(message, privacy: .public)")
            case .missing, .loaded:
                break
            }
        }

        guard !document.isNewerVersion else {
            Self.logger.warning("not changing workspace.json because it is from a newer version")
            return
        }
        var doc = document
        change(&doc)
        guard doc != document else { return }
        document = doc
        writeCurrentDocument()
    }

    /// Write `document` unless the on-disk file is invalid or from a newer
    /// version, or already holds these exact bytes.
    private func writeCurrentDocument() {
        guard loadError == nil else {
            Self.logger.warning("not saving workspace.json because the on-disk file is invalid")
            return
        }
        guard !document.isNewerVersion else {
            Self.logger.warning("not saving workspace.json because it is from a newer version")
            return
        }
        do {
            let data = try document.encoded()
            if data == lastWrittenData { return }
            try Self.writeAtomically(data, to: fileURL)
            lastWrittenData = data
        } catch {
            Self.logger.error("failed to save workspace.json: \(error, privacy: .public)")
        }
    }

    // MARK: - Local files

    /// Read a per-machine file. Nil when missing; an unreadable file is
    /// logged and treated as empty (it only holds this machine's history).
    private static func readLocal<T>(_ url: URL, _ make: (JSONValue) -> T) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return make(try JSONValue.decode(Data(contentsOf: url)))
        } catch {
            logger.error("\(url.lastPathComponent, privacy: .public) could not be read, starting empty: \(error, privacy: .public)")
            return nil
        }
    }

    private func writeRecent() {
        writeLocal(recent.json, to: recentFileURL)
        recentFileExists = true
    }

    private func writeUsage() {
        writeLocal(usage.json, to: usageFileURL)
    }

    /// Same atomic write and permissions as workspace.json.
    private func writeLocal(_ value: JSONValue, to url: URL) {
        do {
            try Self.writeAtomically(value.encodedFile(), to: url)
        } catch {
            Self.logger.error("failed to save \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
        }
    }

    enum WriteError: Error, CustomStringConvertible {
        case createFailed(String)
        case renameFailed(String, Int32)

        var description: String {
            switch self {
            case .createFailed(let path): return "could not create \(path)"
            case .renameFailed(let path, let code): return "rename to \(path) failed (errno \(code))"
            }
        }
    }

    /// Write `data` to `url` via a temp file in the same directory followed by
    /// `rename(2)`. Symlinks are followed so a symlinked file keeps pointing
    /// at its target. The file is created with mode 0600 (directory 0700).
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let directory = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WriteError.createFailed(temp.path)
        }
        if rename(temp.path, target.path) != 0 {
            let code = errno
            try? fm.removeItem(at: temp)
            throw WriteError.renameFailed(target.path, code)
        }
    }
}

// MARK: - Shared instance

extension WorkspaceStore {
    /// The app-wide store owned by `AppDelegate`. Falls back to a private
    /// instance when there is no app delegate (previews, tests without a host).
    static var shared: WorkspaceStore {
        if let delegate = NSApp?.delegate as? AppDelegate {
            return delegate.workspaceStore
        }
        return fallback
    }

    private static let fallback = WorkspaceStore()
}

// MARK: - File watcher

/// Watches a file and its parent directory with `DispatchSource` so both
/// in-place writes and atomic replace (temp file + rename, as used by most
/// editors and sync tools) are noticed. Events are coalesced.
final class WorkspaceFileWatcher {
    private let fileURL: URL
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(fileURL: URL, queue: DispatchQueue = .main, onChange: @escaping () -> Void) {
        self.fileURL = fileURL.resolvingSymlinksInPath()
        self.queue = queue
        self.onChange = onChange
        directorySource = makeSource(path: self.fileURL.deletingLastPathComponent().path)
        fileSource = makeSource(path: self.fileURL.path)
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }

    private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fire() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func fire() {
        pending = nil
        // The file may have been replaced (new inode); re-arm the file source.
        fileSource?.cancel()
        fileSource = makeSource(path: fileURL.path)
        onChange()
    }
}
