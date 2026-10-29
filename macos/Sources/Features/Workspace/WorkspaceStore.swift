import AppKit
import Combine
import OSLog

/// Owns `~/.config/slimer/workspace.json`: loads it, saves it atomically,
/// watches it for external changes (dotfile sync, hand edits) and records
/// usage. One instance is owned by `AppDelegate`; use `WorkspaceStore.shared`
/// from UI code.
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

    /// Set when the file on disk could not be parsed. While set we keep the
    /// in-memory document and never overwrite the file, so a hand edit with a
    /// typo is not clobbered.
    @Published private(set) var loadError: String?

    /// Where the document lives (may be a symlink into a dotfiles repo).
    let fileURL: URL

    private let now: () -> Date
    private let visitDebounce: TimeInterval
    /// The bytes we last read from or successfully wrote to disk. Anything
    /// else on disk is an external edit.
    private var lastWrittenData: Data?
    private var watcher: WorkspaceFileWatcher?
    private var pendingVisit: DispatchWorkItem?
    private var visitGeneration = 0
    private var lastCommittedVisit: (path: String, date: Date)?

    /// Queue for `stat` calls on shell-reported (untrusted) paths so a slow
    /// or hung filesystem never blocks the main thread.
    private static let statQueue = DispatchQueue(label: "slimer.workspace.stat", qos: .utility)

    /// - Parameters:
    ///   - fileURL: the JSON file. Defaults to the XDG-aware location (a temp
    ///     file under XCTest).
    ///   - watch: whether to reload when the file changes on disk. Off by
    ///     default under XCTest.
    ///   - visitDebounce: how long a directory must stay current before it
    ///     counts as a visit.
    ///   - now: clock, injectable for tests.
    init(
        fileURL: URL = WorkspacePath.defaultFileURL(),
        watch: Bool = !WorkspacePath.isRunningUnderXCTest(),
        visitDebounce: TimeInterval = 1.5,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.now = now
        self.visitDebounce = visitDebounce
        self.document = WorkspaceDocument()

        switch Self.read(fileURL) {
        case .missing:
            document = .seed()
            writeCurrentDocument()
            Self.logger.info("seeded \(fileURL.path, privacy: .public)")
        case .loaded(let doc, let data):
            document = doc
            lastWrittenData = data
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

    /// Count a use of a location (also counts a visit to its directory).
    func recordUse(location: WorkspaceLocation) {
        let date = now()
        let path = location.expandedPath
        let recordVisit = WorkspacePath.isRecordable(path)
        if recordVisit {
            // The shell will report this directory right after the cd; don't
            // count it twice.
            lastCommittedVisit = (path, date)
        }
        mutate { doc in
            guard doc.recordUse(locationID: location.id, now: date) else { return }
            if recordVisit { doc.recordVisit(path: path, now: date) }
        }
    }

    /// Count a use of a saved command.
    func recordUse(command: WorkspaceCommand) {
        let date = now()
        mutate { doc in doc.recordUse(commandID: command.id, now: date) }
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
        mutate { doc in doc.recordVisit(path: path, now: date) }
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
            lastWrittenData = data
            if doc != document { document = doc }
        case .invalid(let message):
            loadError = message
            Self.logger.error("workspace.json reload failed: \(message, privacy: .public)")
        }
    }

    /// Apply a change and persist it. If the file changed on disk since we
    /// last read or wrote it (an edit the watcher has not delivered yet), the
    /// disk version is loaded first and the change is re-applied on top, so
    /// external edits are never overwritten. While the file is invalid the
    /// change stays in memory only.
    private func mutate(_ change: (inout WorkspaceDocument) -> Void) {
        if loadError == nil {
            switch Self.read(fileURL) {
            case .loaded(let disk, let data) where data != lastWrittenData:
                document = disk
                lastWrittenData = data
            case .invalid(let message):
                loadError = message
                Self.logger.error("workspace.json became invalid; keeping changes in memory: \(message, privacy: .public)")
            case .missing, .loaded:
                break
            }
        }

        var doc = document
        change(&doc)
        if doc != document { document = doc }
        writeCurrentDocument()
    }

    /// Write `document` unless the on-disk file is invalid or already holds
    /// these exact bytes.
    private func writeCurrentDocument() {
        guard loadError == nil else {
            Self.logger.warning("not saving workspace.json because the on-disk file is invalid")
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
