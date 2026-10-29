import Testing
import Foundation
@testable import Ghostty

struct ClaudeLauncherTests {
    @Test func candidateOrder() {
        let candidates = ClaudeLauncher.defaultCandidates(home: "/Users/me", pathEnvironment: "/a/bin:relative:/opt/homebrew/bin:/b")
        #expect(candidates == [
            "/Users/me/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Users/me/.claude/local/claude",
            "/a/bin/claude",
            "/b/claude",
        ])
    }

    @Test func locatesFirstExecutableFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-launcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        // 1: missing, 2: directory named claude, 3: non-executable file, 4: executable, 5: executable.
        let missing = root.appendingPathComponent("one/claude").path
        let directory = root.appendingPathComponent("two/claude")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let plain = root.appendingPathComponent("three/claude")
        try fm.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: plain)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        let executable = root.appendingPathComponent("four/claude")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let later = root.appendingPathComponent("five/claude")
        try fm.createDirectory(at: later.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: later, withDestinationURL: executable)

        let found = ClaudeLauncher.locate(candidates: [missing, directory.path, plain.path, executable.path, later.path])
        #expect(found?.path == executable.path)

        // Symlinks to an executable count, and are returned unresolved.
        #expect(ClaudeLauncher.locate(candidates: [later.path])?.path == later.path)
        #expect(ClaudeLauncher.locate(candidates: [missing, directory.path, plain.path]) == nil)
    }

    @Test func commandLineQuotesPathAndAddsFlags() {
        let plain = URL(fileURLWithPath: "/Users/me/.local/bin/claude")
        #expect(ClaudeLauncher.commandLine(binary: plain, mode: .new) == "/Users/me/.local/bin/claude")
        #expect(ClaudeLauncher.commandLine(binary: plain, mode: .continueLast) == "/Users/me/.local/bin/claude --continue")
        #expect(ClaudeLauncher.commandLine(binary: plain, mode: .resume) == "/Users/me/.local/bin/claude --resume")
        let spaced = URL(fileURLWithPath: "/Users/Jane Doe/.local/bin/claude")
        #expect(ClaudeLauncher.commandLine(binary: spaced, mode: .new) == "'/Users/Jane Doe/.local/bin/claude'")
    }
}

struct ClaudeProcessDetectorTests {
    @Test(arguments: [
        ("/Users/me/.local/share/claude/versions/2.0.14", [String]()),
        ("/Users/me/.local/bin/claude", []),
        ("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/claude"]),
        ("/opt/homebrew/bin/node", ["node", "--no-warnings", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]),
    ])
    func matchesClaude(path: String, arguments: [String]) {
        #expect(ClaudeProcessDetector.isClaude(executablePath: path, arguments: arguments))
    }

    @Test(arguments: [
        ("/bin/zsh", ["-zsh"]),
        ("/usr/bin/vim", ["vim", "claude"]),
        ("/opt/homebrew/bin/node", ["node", "server.js", "claude"]),
        ("/opt/homebrew/bin/node", ["node"]),
    ])
    func rejectsOthers(path: String, arguments: [String]) {
        #expect(!ClaudeProcessDetector.isClaude(executablePath: path, arguments: arguments))
    }

    @Test func parsesProcArgs() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(2)) { buffer.append(contentsOf: $0) }
        buffer.append(contentsOf: Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0])
        buffer.append(contentsOf: Array("node".utf8) + [0])
        buffer.append(contentsOf: Array("/x/claude".utf8) + [0])
        buffer.append(contentsOf: Array("PATH=/bin".utf8) + [0])
        #expect(ClaudeProcessDetector.parseProcArgs(buffer) == ["node", "/x/claude"])
    }
}
