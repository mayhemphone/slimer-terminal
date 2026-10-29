import Testing
import Combine
import Foundation
@testable import Ghostty

/// End-to-end tests against a real `git` binary. Every test is skipped when git is
/// not available on the restricted search path the service uses.
@MainActor
struct GitStatusServiceIntegrationTests {
    nonisolated private static var gitAvailable: Bool { GitProcessRunner() != nil }

    /// A throwaway repository driven through the same restricted runner the
    /// service uses. Removed on deinit.
    private final class TempRepo {
        struct CommandFailed: Error {
            let arguments: [String]
            let stderr: String
        }

        let runner: GitProcessRunner
        let root: URL

        init(runner: GitProcessRunner) throws {
            self.runner = runner
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("slimer-repo-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try git("init", "-q", "-b", "main")
            try git("config", "user.email", "slimer-tests@example.invalid")
            try git("config", "user.name", "Slimer Tests")
            try git("config", "commit.gpgsign", "false")
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func git(_ arguments: String...) throws -> String {
            let output = runner.run(arguments, in: root, timeout: 10)
            guard output.succeeded else {
                throw CommandFailed(arguments: arguments, stderr: output.stderrText)
            }
            return output.stdoutText
        }

        /// Runs git and ignores a failing exit status (used for a merge that is
        /// expected to conflict).
        func gitAllowingFailure(_ arguments: String...) {
            _ = runner.run(arguments, in: root, timeout: 10)
        }

        func write(_ name: String, _ contents: String) throws {
            try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func commitAll(_ message: String) throws {
            try git("add", "-A")
            try git("commit", "-q", "-m", message)
        }
    }

    private func makeRunner() throws -> GitProcessRunner {
        try #require(GitProcessRunner(), "git not found on the restricted search path")
    }

    /// Poll until `condition` holds or `timeout` elapses.
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test(.enabled(if: gitAvailable, "git not found on the restricted search path"))
    func countsMatchWorkingTree() async throws {
        let runner = try makeRunner()
        let repo = try TempRepo(runner: runner)
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "two\n")
        try repo.commitAll("initial")

        // 1 unstaged (modified tracked), 1 staged (new, added), 1 untracked.
        try repo.write("a.txt", "one changed\n")
        try repo.write("c.txt", "three\n")
        try repo.git("add", "c.txt")
        try repo.write("d.txt", "four\n")

        let service = GitStatusService(runner: runner)
        let state = try #require(await service.refreshedState(for: repo.root))

        #expect(state.branch == "main")
        #expect(state.detachedHead == nil)
        #expect(state.upstream == nil)
        #expect(state.ahead == 0)
        #expect(state.behind == 0)
        #expect(state.staged == 1)
        #expect(state.unstaged == 1)
        #expect(state.untracked == 1)
        #expect(state.conflicted == 0)
        #expect(state.stashCount == 0)
        #expect(state.operation == nil)
        #expect(state.isDirty)
        #expect(state.root.resolvingSymlinksInPath().path == repo.root.resolvingSymlinksInPath().path)

        // A subdirectory resolves to the same root and the same cached entry.
        let sub = repo.root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fromSub = try #require(await service.refreshedState(for: sub))
        #expect(fromSub.root == state.root)
        #expect(service.state(for: sub)?.root == state.root)

        // Stashing clears the tracked changes but leaves the untracked file.
        try repo.git("stash", "push", "-q")
        let stashed = try #require(await service.refreshedState(for: repo.root))
        #expect(stashed.stashCount == 1)
        #expect(stashed.staged == 0)
        #expect(stashed.unstaged == 0)
        #expect(stashed.untracked == 1)

        // Detached HEAD reports a short SHA instead of a branch.
        try repo.git("checkout", "-q", "--detach")
        let detached = try #require(await service.refreshedState(for: repo.root))
        #expect(detached.branch == nil)
        #expect(detached.isDetached)
        #expect(detached.detachedHead?.count == 7)
        #expect(detached.headLabel == detached.detachedHead)

        if let duration = service.lastRefreshDuration(root: state.root) {
            print("GitStatusService refresh took \(Int(duration * 1000)) ms on a temporary repository")
            #expect(duration < 2)
        }
    }

    @Test(.enabled(if: gitAvailable, "git not found on the restricted search path"))
    func upstreamAheadBehind() async throws {
        let runner = try makeRunner()
        let remote = try TempRepo(runner: runner)
        try remote.write("f.txt", "1\n")
        try remote.commitAll("one")

        let clone = try TempRepo(runner: runner)
        try clone.git("remote", "add", "origin", remote.root.path)
        try clone.git("fetch", "-q", "origin")
        try clone.git("checkout", "-q", "-B", "main", "origin/main")

        // One commit ahead locally, one behind on the remote.
        try clone.write("local.txt", "x\n")
        try clone.commitAll("local")
        try remote.write("remote.txt", "y\n")
        try remote.commitAll("remote")
        try clone.git("fetch", "-q", "origin")

        let service = GitStatusService(runner: runner)
        let state = try #require(await service.refreshedState(for: clone.root))
        #expect(state.branch == "main")
        #expect(state.upstream == "origin/main")
        #expect(state.ahead == 1)
        #expect(state.behind == 1)
    }

    @Test(.enabled(if: gitAvailable, "git not found on the restricted search path"))
    func mergeConflictReportsOperationAndConflicts() async throws {
        let runner = try makeRunner()
        let repo = try TempRepo(runner: runner)
        try repo.write("shared.txt", "base\n")
        try repo.commitAll("base")
        try repo.git("switch", "-q", "-c", "other")
        try repo.write("shared.txt", "other\n")
        try repo.commitAll("other")
        try repo.git("switch", "-q", "main")
        try repo.write("shared.txt", "main\n")
        try repo.commitAll("main")
        repo.gitAllowingFailure("merge", "other") // conflicts, exit 1

        let service = GitStatusService(runner: runner)
        let state = try #require(await service.refreshedState(for: repo.root))
        #expect(state.operation == .merge)
        #expect(state.conflicted == 1)
        #expect(state.branch == "main")
    }

    @Test(.enabled(if: gitAvailable, "git not found on the restricted search path"))
    func nonRepositoryDirectoryIsNil() async throws {
        let runner = try makeRunner()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-norepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let service = GitStatusService(runner: runner)
        let plain = await service.refreshedState(for: dir)
        #expect(plain == nil)
        #expect(service.state(for: dir) == nil)

        // Excluded locations never spawn git.
        let root = await service.refreshedState(for: URL(fileURLWithPath: "/", isDirectory: true))
        #expect(root == nil)
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let libraryState = await service.refreshedState(for: library)
        #expect(libraryState == nil)
    }

    @Test(.enabled(if: gitAvailable, "git not found on the restricted search path"))
    func observerReceivesStateAndWatcherPicksUpCommits() async throws {
        let runner = try makeRunner()
        let repo = try TempRepo(runner: runner)
        try repo.write("a.txt", "one\n")
        try repo.commitAll("initial")
        try repo.write("new.txt", "untracked for now\n")

        let service = GitStatusService(runner: runner)
        var received: [GitRepoState?] = []
        let cancellable = service.observe(directory: repo.root).sink { received.append($0) }
        defer { cancellable.cancel() }

        let gotInitial = try await waitUntil { received.last??.untracked == 1 }
        #expect(gotInitial, "observer never received the initial state: \(received)")
        let first = try #require(received.last ?? nil)

        // Committing touches .git/index and .git/HEAD-ref; the watcher must notice
        // without an explicit refresh call.
        try repo.commitAll("add new")
        let gotUpdate = try await waitUntil {
            guard let latest = received.last ?? nil else { return false }
            return latest.untracked == 0 && latest.staged == 0 && latest.updatedAt > first.updatedAt
        }
        #expect(gotUpdate, "watcher did not trigger a refresh: \(received)")
        #expect(service.state(for: repo.root)?.untracked == 0)
    }

    @Test func disabledServiceWithoutGitPublishesNil() async throws {
        let service = GitStatusService(runner: nil)
        #expect(!service.isEnabled)
        #expect(service.state(for: FileManager.default.temporaryDirectory) == nil)
        let refreshed = await service.refreshedState(for: FileManager.default.temporaryDirectory)
        #expect(refreshed == nil)
        let branches = await service.branchList(root: FileManager.default.temporaryDirectory)
        #expect(branches.isEmpty)

        var received: [GitRepoState?] = []
        let cancellable = service.observe(directory: FileManager.default.temporaryDirectory).sink { received.append($0) }
        defer { cancellable.cancel() }
        #expect(received == [nil])
    }

    @Test(.enabled(if: gitAvailable, "git not found on the restricted search path"))
    func branchListIncludesLocalAndRemoteRefs() async throws {
        let runner = try makeRunner()
        let repo = try TempRepo(runner: runner)
        try repo.write("a.txt", "one\n")
        try repo.commitAll("initial")
        try repo.git("branch", "feature/x")
        try repo.git("branch", "it's-quoted")

        let service = GitStatusService(runner: runner)
        let branches = await service.branchList(root: repo.root)
        #expect(branches.contains("main"))
        #expect(branches.contains("feature/x"))
        // `'` cannot be quoted safely for every shell (fish), so it is dropped.
        #expect(!branches.contains("it's-quoted"))
        #expect(Set(branches).count == branches.count)
    }
}

struct GitProcessRunnerTests {
    @Test func environmentIsMinimalAndFixed() {
        let env = GitProcessRunner.makeEnvironment(home: "/Users/test")
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/test")
        #expect(env["LANG"] == "C")
        #expect(env["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["GIT_DIR"] == nil)
        #expect(env["GIT_WORK_TREE"] == nil)
        #expect(env.count == 5)
    }

    /// The runner is a generic subprocess harness; `/bin/sleep` stands in for a git
    /// that hangs, which proves the timeout terminates it.
    @Test func timeoutTerminatesHungProcess() {
        let runner = GitProcessRunner(gitURL: URL(fileURLWithPath: "/bin/sleep"), globalArguments: [])
        let started = Date()
        let output = runner.run(["30"], in: nil, timeout: 0.3)
        #expect(output.timedOut)
        #expect(!output.succeeded)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func passesDirectoryThroughDashC() {
        // `/bin/echo` prints the arguments we would hand to git, which proves `-C <dir>`
        // and the hardening options precede the subcommand.
        let runner = GitProcessRunner(gitURL: URL(fileURLWithPath: "/bin/echo"))
        let output = runner.run(["status"], in: URL(fileURLWithPath: "/tmp/some dir", isDirectory: true), timeout: 2)
        #expect(output.succeeded)
        #expect(output.stdoutText == "-C /tmp/some dir -c core.fsmonitor=false status\n")
    }

    @Test func subprocessSeesOnlyRestrictedEnvironment() {
        let runner = GitProcessRunner(gitURL: URL(fileURLWithPath: "/usr/bin/env"), globalArguments: [])
        let output = runner.run([], in: nil, timeout: 2)
        #expect(output.succeeded)
        let lines = Set(output.stdoutText.split(separator: "\n").map(String.init))
        #expect(lines.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(lines.contains("GIT_TERMINAL_PROMPT=0"))
        #expect(lines.contains("PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"))
        #expect(!lines.contains { $0.hasPrefix("GIT_DIR=") || $0.hasPrefix("GIT_WORK_TREE=") })
    }

    @Test func locatesGitOnRestrictedPathOnly() throws {
        guard let runner = GitProcessRunner() else { return }
        let allowed = GitProcessRunner.searchPath.map { "\($0)/git" }
        #expect(allowed.contains(runner.gitURL.path))
        let version = runner.run(["--version"], in: nil, timeout: 2)
        #expect(version.succeeded)
        #expect(version.stdoutText.hasPrefix("git version"))
    }

    @Test func searchPathPrefersHomebrew() {
        #expect(GitProcessRunner.searchPath == ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
    }
}

/// Uses a fake git directory; no git binary needed.
@MainActor
struct GitRepoWatcherTests {
    @Test func watchesPackedRefsAndRearmsAfterRename() async throws {
        let fm = FileManager.default
        let gitDir = fm.temporaryDirectory.appendingPathComponent("slimer-watch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: gitDir.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: gitDir) }
        try Data("ref: refs/heads/main\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
        let packed = gitDir.appendingPathComponent("packed-refs")
        try Data("# pack-refs\n".utf8).write(to: packed)

        var events = 0
        let watcher = GitRepoWatcher(gitDir: gitDir, commonDir: gitDir) { events += 1 }
        watcher.start()
        defer { watcher.stop() }
        #expect(watcher.watchedPaths.contains(packed.path))

        // Replace packed-refs the way git does: write a temp file, rename over it.
        let temp = gitDir.appendingPathComponent("packed-refs.lock")
        try Data("# pack-refs v2\n".utf8).write(to: temp)
        _ = try fm.replaceItemAt(packed, withItemAt: temp)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, events == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(events > 0)

        // After the re-arm delay the new inode is watched again.
        try await Task.sleep(for: .milliseconds(500))
        #expect(watcher.watchedPaths.contains(packed.path))
    }
}
