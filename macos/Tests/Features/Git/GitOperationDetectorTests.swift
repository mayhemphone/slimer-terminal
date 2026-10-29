import Testing
import Foundation
@testable import Ghostty

/// Uses a throwaway directory with fake `.git` marker files. No git binary needed.
struct GitOperationDetectorTests {
    private func withFakeGitDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-gitdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func touch(_ name: String, in dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    @Test func noMarkersMeansNoOperation() throws {
        try withFakeGitDir { dir in
            #expect(GitOperationDetector.detect(gitDir: dir) == nil)
        }
    }

    @Test func detectsEachMarker() throws {
        let cases: [(String, GitRepoState.Operation)] = [
            ("MERGE_HEAD", .merge),
            ("CHERRY_PICK_HEAD", .cherryPick),
            ("REVERT_HEAD", .revert),
            ("BISECT_LOG", .bisect),
        ]
        for (marker, expected) in cases {
            try withFakeGitDir { dir in
                try touch(marker, in: dir)
                #expect(GitOperationDetector.detect(gitDir: dir) == expected, "marker \(marker)")
            }
        }
    }

    @Test func detectsRebaseDirectories() throws {
        try withFakeGitDir { dir in
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("rebase-merge"), withIntermediateDirectories: false)
            #expect(GitOperationDetector.detect(gitDir: dir) == .rebase)
        }
        try withFakeGitDir { dir in
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("rebase-apply"), withIntermediateDirectories: false)
            #expect(GitOperationDetector.detect(gitDir: dir) == .rebase)
        }
    }

    /// A rebase that stopped on a conflict also leaves `MERGE_HEAD`-like state around;
    /// the rebase must win, matching git's own prompt helper.
    @Test func rebaseTakesPriorityOverMerge() throws {
        try withFakeGitDir { dir in
            try touch("MERGE_HEAD", in: dir)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("rebase-merge"), withIntermediateDirectories: false)
            #expect(GitOperationDetector.detect(gitDir: dir) == .rebase)
        }
    }

    @Test func missingGitDirIsNotAnOperation() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)/.git", isDirectory: true)
        #expect(GitOperationDetector.detect(gitDir: missing) == nil)
    }
}

struct GitPathPolicyTests {
    private let home = "/Users/someone"

    @Test func rejectsFilesystemRoot() {
        #expect(GitPathPolicy.pathSkipReason(path: "/", homePath: home) == .filesystemRoot)
        #expect(GitPathPolicy.pathSkipReason(path: "", homePath: home) == .filesystemRoot)
    }

    @Test func rejectsSystemFolder() {
        #expect(GitPathPolicy.pathSkipReason(path: "/System", homePath: home) == .systemFolder)
        #expect(GitPathPolicy.pathSkipReason(path: "/System/Library/Frameworks", homePath: home) == .systemFolder)
        #expect(GitPathPolicy.pathSkipReason(path: "/SystemX", homePath: home) == nil)
    }

    @Test func rejectsUserLibrary() {
        #expect(GitPathPolicy.pathSkipReason(path: "/Users/someone/Library", homePath: home) == .userLibrary)
        #expect(GitPathPolicy.pathSkipReason(path: "/Users/someone/Library/Caches/x", homePath: home) == .userLibrary)
        #expect(GitPathPolicy.pathSkipReason(path: "/Users/someone/Library", homePath: home + "/") == .userLibrary)
        #expect(GitPathPolicy.pathSkipReason(path: "/Users/someone/LibraryNotes", homePath: home) == nil)
        #expect(GitPathPolicy.pathSkipReason(path: "/Users/other/Library", homePath: home) == nil)
    }

    @Test func allowsOrdinaryDirectories() {
        #expect(GitPathPolicy.pathSkipReason(path: "/Users/someone/Dev/repo", homePath: home) == nil)
        #expect(GitPathPolicy.pathSkipReason(path: "/opt/homebrew", homePath: home) == nil)
    }

    @Test func liveChecksOnLocalTemporaryDirectory() {
        let tmp = FileManager.default.temporaryDirectory
        #expect(GitPathPolicy.skipReason(for: tmp) == nil)

        let missing = tmp.appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        #expect(GitPathPolicy.skipReason(for: missing) == .unreadable)

        #expect(GitPathPolicy.skipReason(for: URL(fileURLWithPath: "/", isDirectory: true)) == .filesystemRoot)
        #expect(GitPathPolicy.skipReason(for: URL(fileURLWithPath: "/System/Library", isDirectory: true)) == .systemFolder)
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        #expect(GitPathPolicy.skipReason(for: library) == .userLibrary)
    }
}
