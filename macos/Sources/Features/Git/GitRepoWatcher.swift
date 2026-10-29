import Foundation

/// Watches the handful of paths inside a git directory that change whenever the
/// repository state changes, and fires a callback on the main queue.
///
/// Git replaces `HEAD`, `index` and loose refs atomically (write a temp file, then
/// rename over the target), so a vnode source on the old inode sees a delete and
/// must be re-armed on the new file. Directory sources on `.git`, `refs/` and
/// `refs/heads/` catch those renames as well as the appearance of marker files such
/// as `MERGE_HEAD`. Nothing here reads file contents.
@MainActor
final class GitRepoWatcher {
    /// Delay before re-opening a watched file that was replaced. Short enough to
    /// not miss follow-up changes, long enough for git to finish its rename.
    private static let rearmDelay: TimeInterval = 0.2

    private struct Target {
        let url: URL
        let isDirectory: Bool
    }

    private let targets: [Target]
    private let onChange: @MainActor () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var rearmScheduled = false
    private var isRunning = false

    /// - Parameters:
    ///   - gitDir: `.git` or the worktree-private git directory (holds `HEAD`, `index`
    ///     and operation marker files).
    ///   - commonDir: the shared git directory (holds `refs/` and `packed-refs`). Equal
    ///     to `gitDir` for a normal checkout.
    ///   - onChange: invoked on the main queue, already coalesced per burst by the
    ///     kernel but not debounced; the service debounces.
    init(gitDir: URL, commonDir: URL, onChange: @escaping @MainActor () -> Void) {
        var targets: [Target] = [
            Target(url: gitDir, isDirectory: true),
            Target(url: gitDir.appendingPathComponent("HEAD"), isDirectory: false),
            Target(url: gitDir.appendingPathComponent("index"), isDirectory: false),
            Target(url: commonDir.appendingPathComponent("refs"), isDirectory: true),
            Target(url: commonDir.appendingPathComponent("refs/heads"), isDirectory: true),
            Target(url: commonDir.appendingPathComponent("refs/remotes"), isDirectory: true),
        ]
        if commonDir.standardizedFileURL.path != gitDir.standardizedFileURL.path {
            targets.append(Target(url: commonDir, isDirectory: true))
        }
        self.targets = targets
        self.onChange = onChange
    }

    deinit {
        for source in sources.values {
            source.cancel()
        }
    }

    /// Paths currently held open. Exposed for tests.
    var watchedPaths: [String] { sources.keys.sorted() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        armMissing()
    }

    func stop() {
        isRunning = false
        for source in sources.values {
            source.cancel()
        }
        sources.removeAll()
    }

    // MARK: Private

    /// Open a source for every target that does not currently have one. Targets that
    /// do not exist yet (for example `refs/remotes` before the first fetch, or `index`
    /// in a fresh repository) are simply retried on the next directory event.
    private func armMissing() {
        guard isRunning else { return }
        for target in targets where sources[target.url.path] == nil {
            arm(target)
        }
    }

    private func arm(_ target: Target) {
        let path = target.url.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let mask: DispatchSource.FileSystemEvent = target.isDirectory
            ? [.write, .delete, .rename, .revoke]
            : [.write, .extend, .attrib, .delete, .rename, .revoke]
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = source.data
                self.handleEvent(event, at: path)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        sources[path] = source
        source.resume()
    }

    private func handleEvent(_ event: DispatchSource.FileSystemEvent, at path: String) {
        guard isRunning else { return }
        if !event.isDisjoint(with: [.delete, .rename, .revoke]) {
            // The inode we hold is gone; drop it and pick up the replacement shortly.
            sources.removeValue(forKey: path)?.cancel()
        }
        scheduleRearm()
        onChange()
    }

    private func scheduleRearm() {
        guard !rearmScheduled else { return }
        rearmScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rearmDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rearmScheduled = false
                self.armMissing()
            }
        }
    }
}
