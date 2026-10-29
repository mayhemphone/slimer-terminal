import Combine
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "slimer",
    category: "GitStatusService"
)

/// Read-only provider of git state for the directories terminal surfaces live in.
///
/// One shared instance serves every surface. Callers hand it a working directory
/// (typically the surface's OSC 7 pwd); it resolves the repository root, runs
/// `git status` out of process on a background queue, and publishes a
/// `GitRepoState` per root on the main actor. It never runs a mutating command.
///
/// Refresh pipeline:
/// 1. `directory -> root` resolution through one `git rev-parse` call, cached for
///    30 s (negative results too).
/// 2. `git status --porcelain=v2 --branch -z` (plus `git stash list` when the
///    `--show-stash` header is unavailable), hard 2 s timeout, serial queue.
/// 3. Refreshes are debounced to 250 ms per root and never overlap for one root.
///
/// Triggers: `refresh(root:)` / `refresh(directory:)`, a vnode watcher on the
/// repository's `.git` directory while at least one observer exists, and the
/// first subscription of an observer.
@MainActor
final class GitStatusService: ObservableObject {
    static let shared = GitStatusService()

    /// Where a directory's repository lives.
    struct RepoLocation: Hashable, Sendable {
        /// Working tree root.
        let root: URL
        /// Git directory holding `HEAD`, `index` and operation markers.
        let gitDir: URL
        /// Shared git directory holding `refs/`. Same as `gitDir` outside linked worktrees.
        let commonDir: URL
    }

    nonisolated static let rootCacheLifetime: TimeInterval = 30
    nonisolated static let debounceInterval: TimeInterval = 0.25
    nonisolated static let watcherLinger: TimeInterval = 60
    nonisolated static let commandTimeout: TimeInterval = 2

    /// Latest known state per repository root. Published for SwiftUI consumers that
    /// prefer observing the whole map over `observe(directory:)`.
    @Published private(set) var states: [URL: GitRepoState] = [:]

    /// The subprocess runner, or `nil` when no `git` binary was found on the
    /// restricted search path. When `nil` the service is disabled and only ever
    /// publishes `nil`.
    let runner: GitProcessRunner?

    var isEnabled: Bool { runner != nil }

    private let workQueue = DispatchQueue(label: "top.mayhem.slimer.git-status", qos: .utility)
    private var rootCache: [String: RootCacheEntry] = [:]
    private var pendingResolutions: [String: [CheckedContinuation<RepoLocation?, Never>]] = [:]
    private var repos: [String: RepoEntry] = [:]
    private var showStashSupported = true

    init(runner: GitProcessRunner? = GitProcessRunner()) {
        self.runner = runner
        if runner == nil {
            logger.notice("git not found on restricted search path; git status disabled")
        }
    }

    // MARK: Public API

    /// The cached state for the repository containing `directory`, if known.
    ///
    /// Returns `nil` immediately for unknown directories and starts resolving them
    /// in the background, so a later call (or an observer) sees the result.
    func state(for directory: URL) -> GitRepoState? {
        guard isEnabled else { return nil }
        let key = Self.key(directory)
        if let cached = rootCache[key], cached.isValid {
            guard let location = cached.location else { return nil }
            return repos[Self.key(location.root)]?.subject.value
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let location = await self.location(for: directory) else { return }
            self.requestRefresh(self.entry(for: location))
        }
        return nil
    }

    /// A stream of states for the repository containing `directory`.
    ///
    /// Emits the current value on subscription (possibly `nil` while resolving),
    /// then every refreshed state. Emits `nil` when the directory is not inside a
    /// repository or is excluded by `GitPathPolicy`. Subscribe and receive on the
    /// main thread. While at least one subscriber exists the repository's `.git`
    /// directory is watched; the watcher is dropped 60 s after the last one leaves.
    ///
    /// Each returned publisher is meant for one subscriber: work starts on the first
    /// subscription and stops on the first cancellation.
    func observe(directory: URL) -> AnyPublisher<GitRepoState?, Never> {
        let observation = Observation()
        return observation.subject
            .handleEvents(
                receiveSubscription: { [weak self] _ in
                    Self.onMain { self?.activate(observation, directory: directory) }
                },
                receiveCancel: { [weak self] in
                    Self.onMain { self?.detach(observation) }
                }
            )
            .eraseToAnyPublisher()
    }

    /// Request a (debounced, coalesced) refresh of the repository rooted at `root`.
    /// If `root` is not a known root it is treated like `refresh(directory:)`.
    func refresh(root: URL) {
        if let entry = repos[Self.key(root)] {
            requestRefresh(entry)
        } else {
            refresh(directory: root)
        }
    }

    /// Request a (debounced, coalesced) refresh of whichever repository contains
    /// `directory`.
    func refresh(directory: URL) {
        guard isEnabled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let location = await self.location(for: directory) else { return }
            self.requestRefresh(self.entry(for: location))
        }
    }

    /// Resolve `directory`, run a refresh now (skipping the debounce) and return the
    /// resulting state. `nil` when the directory is not inside a repository, the
    /// service is disabled, or git failed.
    func refreshedState(for directory: URL) async -> GitRepoState? {
        guard let location = await location(for: directory) else { return nil }
        let entry = entry(for: location)
        return await withCheckedContinuation { continuation in
            entry.waiters.append(continuation)
            entry.debounce?.cancel()
            entry.debounce = nil
            startRefresh(entry)
        }
    }

    /// Local and remote branch names (`refs/heads`, `refs/remotes`) in ref order.
    /// Names that fail `GitShellQuoting.validate` are dropped.
    func branchList(root: URL) async -> [String] {
        guard let runner else { return [] }
        let output = await onWorkQueue {
            runner.run(
                ["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"],
                in: root,
                timeout: Self.commandTimeout
            )
        }
        guard output.succeeded else { return [] }
        var seen = Set<String>()
        return output.stdoutText
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && GitShellQuoting.isSafe($0) && seen.insert($0).inserted }
    }

    /// Wall-clock duration of the most recent completed refresh for `root`.
    func lastRefreshDuration(root: URL) -> TimeInterval? {
        repos[Self.key(root)]?.lastDuration
    }

    /// Drop every cached root and state. Intended for tests.
    func resetCaches() {
        rootCache.removeAll()
        for entry in repos.values {
            entry.watcher?.stop()
            entry.debounce?.cancel()
            entry.lingerTeardown?.cancel()
        }
        repos.removeAll()
        states.removeAll()
    }

    // MARK: Per-repository bookkeeping

    private struct RootCacheEntry {
        let location: RepoLocation?
        let expires: Date
        var isValid: Bool { expires > Date() }
    }

    @MainActor
    private final class RepoEntry {
        let location: RepoLocation
        let subject = CurrentValueSubject<GitRepoState?, Never>(nil)
        var observers = 0
        var watcher: GitRepoWatcher?
        var lingerTeardown: DispatchWorkItem?
        var debounce: DispatchWorkItem?
        var inFlight = false
        var rerunRequested = false
        var lastDuration: TimeInterval?
        /// Continuations waiting for the *next* refresh to complete.
        var waiters: [CheckedContinuation<GitRepoState?, Never>] = []

        init(location: RepoLocation) {
            self.location = location
        }
    }

    @MainActor
    private final class Observation {
        let subject = CurrentValueSubject<GitRepoState?, Never>(nil)
        var entry: RepoEntry?
        var upstream: AnyCancellable?
        var activated = false
        var cancelled = false
    }

    /// Run `body` on the main actor: synchronously when already on the main thread
    /// (so the first subscription can emit a cached state immediately), otherwise
    /// hopping over.
    nonisolated private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    nonisolated private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func entry(for location: RepoLocation) -> RepoEntry {
        let key = Self.key(location.root)
        if let existing = repos[key] {
            return existing
        }
        let entry = RepoEntry(location: location)
        repos[key] = entry
        return entry
    }

    private func activate(_ observation: Observation, directory: URL) {
        guard !observation.activated, !observation.cancelled else { return }
        observation.activated = true
        guard isEnabled else { return }

        let key = Self.key(directory)
        if let cached = rootCache[key], cached.isValid {
            // Fast path: emit the known state synchronously on subscription.
            if let location = cached.location {
                attach(observation, to: entry(for: location))
            }
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let location = await self.location(for: directory)
            guard !observation.cancelled else { return }
            guard let location else {
                observation.subject.send(nil)
                return
            }
            self.attach(observation, to: self.entry(for: location))
        }
    }

    private func attach(_ observation: Observation, to entry: RepoEntry) {
        observation.entry = entry
        observation.upstream = entry.subject.sink { [weak observation] state in
            observation?.subject.send(state)
        }
        entry.observers += 1
        entry.lingerTeardown?.cancel()
        entry.lingerTeardown = nil
        ensureWatcher(entry)
        requestRefresh(entry)
    }

    private func detach(_ observation: Observation) {
        guard !observation.cancelled else { return }
        observation.cancelled = true
        observation.upstream = nil
        guard let entry = observation.entry else { return }
        observation.entry = nil
        entry.observers = max(0, entry.observers - 1)
        guard entry.observers == 0 else { return }

        let teardown = DispatchWorkItem { [weak self, weak entry] in
            MainActor.assumeIsolated {
                guard self != nil, let entry, entry.observers == 0 else { return }
                entry.watcher?.stop()
                entry.watcher = nil
                entry.lingerTeardown = nil
            }
        }
        entry.lingerTeardown = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watcherLinger, execute: teardown)
    }

    private func ensureWatcher(_ entry: RepoEntry) {
        guard entry.watcher == nil else { return }
        let watcher = GitRepoWatcher(
            gitDir: entry.location.gitDir,
            commonDir: entry.location.commonDir
        ) { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.requestRefresh(entry)
        }
        watcher.start()
        entry.watcher = watcher
    }

    // MARK: Root resolution

    private func location(for directory: URL) async -> RepoLocation? {
        guard let runner else { return nil }
        let key = Self.key(directory)
        if let cached = rootCache[key], cached.isValid {
            return cached.location
        }
        if pendingResolutions[key] != nil {
            // Another caller is already resolving this directory; join it.
            return await withCheckedContinuation { continuation in
                pendingResolutions[key, default: []].append(continuation)
            }
        }
        pendingResolutions[key] = []

        let location = await onWorkQueue {
            Self.resolve(directory: directory, runner: runner)
        }
        rootCache[key] = RootCacheEntry(location: location, expires: Date().addingTimeInterval(Self.rootCacheLifetime))
        if let location {
            _ = entry(for: location)
        }
        let waiters = pendingResolutions.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.resume(returning: location)
        }
        return location
    }

    /// Runs on the work queue. One `rev-parse` call answers root, git dir and
    /// common dir at once.
    nonisolated private static func resolve(directory: URL, runner: GitProcessRunner) -> RepoLocation? {
        if let reason = GitPathPolicy.skipReason(for: directory) {
            logger.debug("skipping \(directory.path, privacy: .private): \(String(describing: reason), privacy: .public)")
            return nil
        }
        let output = runner.run(
            ["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-common-dir"],
            in: directory,
            timeout: commandTimeout
        )
        guard output.succeeded else { return nil }
        let lines = output.stdoutText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, lines[0].hasPrefix("/"), lines[1].hasPrefix("/") else { return nil }

        let root = URL(fileURLWithPath: lines[0], isDirectory: true).standardizedFileURL
        let gitDir = URL(fileURLWithPath: lines[1], isDirectory: true).standardizedFileURL
        // `--git-common-dir` may be relative to the `-C` directory.
        let commonDir: URL
        if lines[2].hasPrefix("/") {
            commonDir = URL(fileURLWithPath: lines[2], isDirectory: true).standardizedFileURL
        } else {
            commonDir = URL(fileURLWithPath: lines[2], isDirectory: true, relativeTo: directory).standardizedFileURL
        }
        return RepoLocation(root: root, gitDir: gitDir, commonDir: commonDir)
    }

    // MARK: Refresh

    private func requestRefresh(_ entry: RepoEntry) {
        guard entry.debounce == nil else { return }
        let item = DispatchWorkItem { [weak self, weak entry] in
            MainActor.assumeIsolated {
                guard let self, let entry else { return }
                entry.debounce = nil
                self.startRefresh(entry)
            }
        }
        entry.debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }

    private func startRefresh(_ entry: RepoEntry) {
        guard let runner else { return }
        if entry.inFlight {
            entry.rerunRequested = true
            return
        }
        entry.inFlight = true
        let waiters = entry.waiters
        entry.waiters = []
        let location = entry.location
        let showStash = showStashSupported

        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.onWorkQueue {
                Self.fetchState(location: location, runner: runner, showStash: showStash)
            }
            entry.inFlight = false
            entry.lastDuration = result.duration
            if result.showStashUnsupported {
                self.showStashSupported = false
            }
            self.publish(result.outcome, for: entry)
            for waiter in waiters {
                waiter.resume(returning: entry.subject.value)
            }
            if !entry.waiters.isEmpty {
                self.startRefresh(entry)
            } else if entry.rerunRequested {
                entry.rerunRequested = false
                self.requestRefresh(entry)
            }
        }
    }

    private func publish(_ outcome: RefreshOutcome, for entry: RepoEntry) {
        switch outcome {
        case .state(let state):
            states[entry.location.root] = state
            entry.subject.send(state)
        case .notARepository:
            // The repository vanished under us; forget it and tell observers.
            states[entry.location.root] = nil
            entry.subject.send(nil)
            let rootKey = Self.key(entry.location.root)
            rootCache = rootCache.filter { $0.value.location.map { Self.key($0.root) } != rootKey }
        case .failed:
            // Transient (timeout, lock contention): keep the last good state.
            break
        }
    }

    private enum RefreshOutcome: Sendable {
        case state(GitRepoState)
        case notARepository
        case failed
    }

    private struct RefreshResult: Sendable {
        let outcome: RefreshOutcome
        let duration: TimeInterval
        let showStashUnsupported: Bool
    }

    /// Runs on the work queue.
    nonisolated private static func fetchState(location: RepoLocation, runner: GitProcessRunner, showStash: Bool) -> RefreshResult {
        let started = Date()
        var arguments = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal"]
        if showStash {
            arguments.append("--show-stash")
        }
        var showStashUnsupported = false
        var output = runner.run(arguments, in: location.root, timeout: commandTimeout)
        if !output.succeeded, showStash, !output.timedOut, output.stderrText.contains("show-stash") {
            // Older git: retry once without the flag and remember that.
            showStashUnsupported = true
            arguments.removeLast()
            output = runner.run(arguments, in: location.root, timeout: commandTimeout)
        }

        guard output.succeeded else {
            let outcome: RefreshOutcome = output.stderrText.contains("not a git repository") ? .notARepository : .failed
            return RefreshResult(outcome: outcome, duration: Date().timeIntervalSince(started), showStashUnsupported: showStashUnsupported)
        }

        let parsed = GitPorcelainParser.parse(output.stdout)

        // git only prints `# stash N` when N > 0, so when `--show-stash` was accepted
        // a missing header means an empty stash. Only older git needs `stash list`.
        let stashCount: Int
        if let stash = parsed.stash {
            stashCount = stash
        } else if arguments.last == "--show-stash" {
            stashCount = 0
        } else {
            let stashOutput = runner.run(["stash", "list", "--format=%gd"], in: location.root, timeout: commandTimeout)
            stashCount = stashOutput.succeeded
                ? stashOutput.stdoutText.split(separator: "\n").filter { !$0.isEmpty }.count
                : 0
        }

        let state = GitRepoState(
            root: location.root,
            branch: parsed.isDetached ? nil : parsed.head,
            detachedHead: parsed.isDetached ? parsed.shortOID : nil,
            upstream: parsed.upstream,
            ahead: parsed.ahead,
            behind: parsed.behind,
            staged: parsed.staged,
            unstaged: parsed.unstaged,
            untracked: parsed.untracked,
            conflicted: parsed.conflicted,
            stashCount: stashCount,
            operation: GitOperationDetector.detect(gitDir: location.gitDir),
            updatedAt: Date()
        )
        return RefreshResult(outcome: .state(state), duration: Date().timeIntervalSince(started), showStashUnsupported: showStashUnsupported)
    }

    // MARK: Queue hop

    private func onWorkQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            workQueue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
