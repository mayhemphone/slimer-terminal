import Testing
import Foundation
@testable import Ghostty

/// Fixtures mirror real `git status --porcelain=v2 --branch -z` output. `\0` stands
/// in for the NUL terminator git emits after every record.
struct GitPorcelainParserTests {
    private let oid = "1234567890abcdef1234567890abcdef12345678"

    @Test func parsesFullStatus() {
        let fixture = [
            "# branch.oid \(oid)",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "# stash 3",
            "1 M. N... 100644 100644 100644 \(oid) \(oid) staged.txt",
            "1 .M N... 100644 100644 100644 \(oid) \(oid) unstaged.txt",
            "1 MM N... 100644 100644 100644 \(oid) \(oid) both.txt",
            "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 \(oid) added.txt",
            "1 .D N... 100644 100644 000000 \(oid) \(oid) deleted.txt",
            "u UU N... 100644 100644 100644 100644 \(oid) \(oid) \(oid) conflict.txt",
            "? untracked.txt",
            "! ignored.o",
        ].joined(separator: "\0") + "\0"

        let status = GitPorcelainParser.parse(fixture)

        #expect(status.oid == oid)
        #expect(status.shortOID == "1234567")
        #expect(status.head == "main")
        #expect(!status.isDetached)
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2)
        #expect(status.behind == 1)
        #expect(status.stash == 3)
        // staged: M., MM, A.  -> 3
        #expect(status.staged == 3)
        // unstaged: .M, MM, .D -> 3
        #expect(status.unstaged == 3)
        #expect(status.conflicted == 1)
        #expect(status.untracked == 1)
        #expect(status.ignored == 1)
    }

    /// Rename records carry the original path as a second NUL-terminated field. That
    /// field must be consumed, otherwise a path such as `? old.txt` would be
    /// miscounted as an untracked record.
    @Test func renameRecordConsumesSecondPathField() {
        let fixture = [
            "# branch.head main",
            "2 R. N... 100644 100644 100644 \(oid) \(oid) R100 new.txt",
            "? old.txt",            // the original path, looks like an untracked record
            "2 .R N... 100644 100644 100644 \(oid) \(oid) R075 moved.txt",
            "1 trap.txt",           // original path, looks like a changed record
            "? really-untracked.txt",
        ].joined(separator: "\0") + "\0"

        let status = GitPorcelainParser.parse(fixture)

        #expect(status.staged == 1)
        #expect(status.unstaged == 1)
        #expect(status.untracked == 1)
    }

    @Test func renameAsLastRecordWithoutTrailingNUL() {
        let fixture = "2 R. N... 100644 100644 100644 \(oid) \(oid) R100 b.txt\0a.txt"
        let status = GitPorcelainParser.parse(fixture)
        #expect(status.staged == 1)
        #expect(status.unstaged == 0)
        #expect(status.untracked == 0)
    }

    @Test func detachedHead() {
        let fixture = "# branch.oid \(oid)\0# branch.head (detached)\0"
        let status = GitPorcelainParser.parse(fixture)
        #expect(status.isDetached)
        #expect(status.head == nil)
        #expect(status.shortOID == "1234567")
        #expect(status.upstream == nil)
    }

    @Test func unbornBranch() {
        let fixture = "# branch.oid (initial)\0# branch.head main\0? README.md\0"
        let status = GitPorcelainParser.parse(fixture)
        #expect(status.oid == nil)
        #expect(status.shortOID == nil)
        #expect(status.head == "main")
        #expect(!status.isDetached)
        #expect(status.untracked == 1)
    }

    @Test func upstreamWithoutAheadBehindHeader() {
        let fixture = "# branch.oid \(oid)\0# branch.head main\0# branch.upstream origin/main\0"
        let status = GitPorcelainParser.parse(fixture)
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
        #expect(status.stash == nil)
    }

    @Test func emptyOutput() {
        #expect(GitPorcelainParser.parse(Data()) == GitPorcelainParser.Status())
        #expect(GitPorcelainParser.parse("") == GitPorcelainParser.Status())
        #expect(GitPorcelainParser.parse("\0\0") == GitPorcelainParser.Status())
    }

    @Test func missingTrailingNULStillParsesLastRecord() {
        let fixture = "# branch.head main\0? a.txt\0? b.txt"
        let status = GitPorcelainParser.parse(fixture)
        #expect(status.head == "main")
        #expect(status.untracked == 2)
    }

    @Test func ignoresUnknownAndMalformedRecords() {
        let fixture = [
            "x something new",
            "1",                 // too short for an XY pair
            "# branch.head",     // header without a value
            "# unknown.key value",
            "# branch.ab nonsense",
            "? ok.txt",
        ].joined(separator: "\0") + "\0"

        let status = GitPorcelainParser.parse(fixture)
        #expect(status.head == nil)
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
        #expect(status.staged == 0)
        #expect(status.untracked == 1)
    }

    @Test func pathsWithSpacesAndNewlinesAreSingleRecords() {
        // With -z, a newline inside a path is literal, not a record separator.
        let fixture = "1 .M N... 100644 100644 100644 \(oid) \(oid) weird\nname with spaces.txt\0? other\nfile\0"
        let status = GitPorcelainParser.parse(fixture)
        #expect(status.unstaged == 1)
        #expect(status.untracked == 1)
        #expect(status.staged == 0)
    }

    @Test func invalidUTF8InPathDoesNotBreakCounting() {
        var data = Data("# branch.head main\0? ".utf8)
        data.append(contentsOf: [0xFF, 0xFE, 0x41])
        data.append(0)
        data.append(contentsOf: Data("? fine.txt\0".utf8))
        let status = GitPorcelainParser.parse(data)
        #expect(status.head == "main")
        #expect(status.untracked == 2)
    }

    @Test func branchNamesContainingSpacesInHeaderArePreserved() {
        // Not valid for git, but the header split must only break on the first two spaces.
        let fixture = "# branch.upstream origin/feature x\0"
        let status = GitPorcelainParser.parse(fixture)
        #expect(status.upstream == "origin/feature x")
    }
}
