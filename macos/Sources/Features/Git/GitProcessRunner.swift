import Foundation
import os

/// Runs read-only `git` subcommands out of process with a restricted environment
/// and a hard timeout.
///
/// Security posture (see `docs/slimer/GIT.md`):
/// - `git` is located only on a fixed search path; `$PATH` from the user's shell is
///   never consulted.
/// - The subprocess environment is built from scratch: no `GIT_DIR`, `GIT_WORK_TREE`
///   or other inherited variables leak in.
/// - Callers pass fixed argument lists; the only user-controlled value is the
///   directory passed through `-C`, which git treats as a path, never an option.
/// - Every run is bounded by a timeout after which the process is terminated and,
///   failing that, killed.
final class GitProcessRunner: Sendable {
    /// Result of one subprocess run.
    struct Output: Sendable {
        var terminationStatus: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
        var duration: TimeInterval

        var succeeded: Bool { terminationStatus == 0 && !timedOut }

        /// stdout as UTF-8, or empty when it is not valid UTF-8. Callers that need to
        /// survive arbitrary bytes (the porcelain parser) read `stdout` directly.
        var stdoutText: String { String(bytes: stdout, encoding: .utf8) ?? "" }
        /// stderr as UTF-8, or empty when it is not valid UTF-8.
        var stderrText: String { String(bytes: stderr, encoding: .utf8) ?? "" }
    }

    /// The fixed search path used to locate `git` and exported as `PATH`.
    /// Homebrew first: it is faster to start than Apple's `/usr/bin/git` xcrun shim.
    static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// Global options placed before every subcommand.
    static let hardeningArguments = ["-c", "core.fsmonitor=false"]

    /// The default hard timeout applied to each invocation.
    static let defaultTimeout: TimeInterval = 2

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "slimer",
        category: String(describing: GitProcessRunner.self)
    )

    /// Absolute path of the git executable in use.
    let gitURL: URL

    /// Environment passed to every subprocess.
    let environment: [String: String]

    /// A queue used to drain pipes and arm timeouts. Concurrent on purpose so both
    /// pipes of one process can be drained at once.
    private let helperQueue = DispatchQueue(label: "top.mayhem.slimer.git-process", qos: .utility, attributes: .concurrent)

    /// Locate `git` on the restricted search path. Returns `nil` when no usable
    /// binary exists, in which case the whole git feature is disabled.
    convenience init?(fileManager: FileManager = .default) {
        guard let url = Self.locateGit(fileManager: fileManager) else { return nil }
        self.init(gitURL: url)
    }

    /// Global options placed before every subcommand by this runner.
    let globalArguments: [String]

    /// Designated initialiser; exposed so tests can point at a specific binary.
    /// `globalArguments` defaults to `hardeningArguments`; tests that use a non-git
    /// stand-in binary pass `[]`.
    init(gitURL: URL, globalArguments: [String] = GitProcessRunner.hardeningArguments) {
        self.gitURL = gitURL
        self.globalArguments = globalArguments
        self.environment = Self.makeEnvironment()
    }

    /// Run `git <arguments>` with the given working directory passed via `-C`.
    ///
    /// This call blocks the calling thread for up to `timeout` seconds and must be
    /// invoked from a background queue.
    func run(_ arguments: [String], in directory: URL?, timeout: TimeInterval = GitProcessRunner.defaultTimeout) -> Output {
        var fullArguments: [String] = []
        if let directory {
            fullArguments += ["-C", directory.path]
        }
        // A repository's own config could name an fsmonitor hook command that
        // `status` would run. Never let a repo the user merely `cd`s into do that.
        fullArguments += globalArguments
        fullArguments += arguments

        let process = Process()
        process.executableURL = gitURL
        process.arguments = fullArguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // `waitUntilExit()` waits by polling the run loop and added ~45 ms per call in
        // measurements; a termination handler signals as soon as the child is reaped.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let started = Date()
        do {
            try process.run()
        } catch {
            Self.logger.error("failed to launch git: \(error.localizedDescription, privacy: .public)")
            return Output(terminationStatus: -1, stdout: Data(), stderr: Data(), timedOut: false, duration: 0)
        }

        // Drain both pipes concurrently so a chatty stderr cannot block stdout.
        let stdoutBox = OSAllocatedUnfairLock(initialState: Data())
        let stderrBox = OSAllocatedUnfairLock(initialState: Data())
        let group = DispatchGroup()
        group.enter()
        helperQueue.async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutBox.withLock { $0 = data }
            group.leave()
        }
        group.enter()
        helperQueue.async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrBox.withLock { $0 = data }
            group.leave()
        }

        // Hard timeout: SIGTERM first, then SIGKILL shortly after if it ignored us.
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let pid = process.processIdentifier
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
            self.helperQueue.asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
        helperQueue.asyncAfter(deadline: .now() + timeout, execute: killer)

        exited.wait()
        killer.cancel()

        // Pipes close when the child exits. Bound the wait anyway in case a
        // grandchild inherited them and keeps them open.
        _ = group.wait(timeout: .now() + 1)

        let output = Output(
            terminationStatus: process.terminationStatus,
            stdout: stdoutBox.withLock { $0 },
            stderr: stderrBox.withLock { $0 },
            timedOut: timedOut.withLock { $0 },
            duration: Date().timeIntervalSince(started)
        )
        if output.timedOut {
            Self.logger.warning("git \(arguments.first ?? "", privacy: .public) timed out after \(timeout)s")
        }
        return output
    }

    // MARK: Environment

    /// Build the minimal environment for git. Nothing is inherited.
    static func makeEnvironment(home: String = NSHomeDirectory()) -> [String: String] {
        [
            "PATH": searchPath.joined(separator: ":"),
            "HOME": home,
            "LANG": "C",
            // Never take the index lock for read-only operations such as `status`.
            "GIT_OPTIONAL_LOCKS": "0",
            // Never block on a credential or passphrase prompt.
            "GIT_TERMINAL_PROMPT": "0",
        ]
    }

    /// Find the first executable `git` on the restricted search path.
    ///
    /// `/usr/bin/git` on macOS is a shim that opens a GUI "install developer tools"
    /// dialog when the Command Line Tools are missing. That shim is only accepted
    /// when `xcode-select -p` reports an installed developer directory, so the app
    /// never triggers that dialog on its own.
    static func locateGit(fileManager: FileManager = .default) -> URL? {
        for directory in searchPath {
            let candidate = "\(directory)/git"
            guard fileManager.isExecutableFile(atPath: candidate) else { continue }
            if candidate == "/usr/bin/git", !developerToolsInstalled() {
                continue
            }
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private static func developerToolsInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
