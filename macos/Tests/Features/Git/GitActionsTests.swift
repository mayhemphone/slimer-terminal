import Testing
import Foundation
@testable import Ghostty

struct GitShellQuotingTests {
    @Test(arguments: ["main", "feature/foo-bar_1.2", "release/v1.0.0", "user@host", "a.b.c"])
    func plainNamesAreNotQuoted(name: String) throws {
        #expect(try GitShellQuoting.quote(name) == name)
    }

    @Test func namesNeedingQuotesAreSingleQuoted() throws {
        #expect(try GitShellQuoting.quote("has space") == "'has space'")
        #expect(try GitShellQuoting.quote("a;b") == "'a;b'")
        #expect(try GitShellQuoting.quote("$(rm -rf ~)") == "'$(rm -rf ~)'")
        #expect(try GitShellQuoting.quote("`id`") == "'`id`'")
        #expect(try GitShellQuoting.quote("a|b&&c") == "'a|b&&c'")
        #expect(try GitShellQuoting.quote("ünïcödé") == "'ünïcödé'")
    }

    @Test func embeddedSingleQuotesAreEscaped() throws {
        #expect(try GitShellQuoting.quote("it's") == "'it'\\''s'")
        #expect(try GitShellQuoting.quote("'") == "''\\'''")
    }

    @Test func rejectsEmpty() {
        #expect(throws: GitShellQuoting.ValidationError.empty) {
            try GitShellQuoting.quote("")
        }
    }

    @Test func rejectsLeadingDash() {
        #expect(throws: GitShellQuoting.ValidationError.leadingDash) {
            try GitShellQuoting.quote("-x")
        }
        #expect(throws: GitShellQuoting.ValidationError.leadingDash) {
            try GitShellQuoting.quote("--force")
        }
    }

    @Test(arguments: [
        "a\nb",        // newline
        "a\rb",        // carriage return
        "a\tb",        // tab
        "a\u{1B}b",    // escape
        "a\u{7F}b",    // DEL
        "a\u{85}b",    // C1 NEL
        "a\u{2028}b",  // line separator
        "a\u{2029}b",  // paragraph separator
        "a\u{202E}b",  // right-to-left override
        "a\u{202A}b",  // left-to-right embedding
        "a\u{2066}b",  // left-to-right isolate
        "a\u{2069}b",  // pop directional isolate
        "\u{0}",       // NUL
    ])
    func rejectsControlAndBidiCharacters(name: String) {
        #expect(throws: GitShellQuoting.ValidationError.containsControlCharacters) {
            try GitShellQuoting.quote(name)
        }
        #expect(!GitShellQuoting.isSafe(name))
    }
}

struct GitActionsTests {
    private let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)

    private func state(
        branch: String? = "main",
        upstream: String? = nil,
        staged: Int = 0,
        unstaged: Int = 0,
        stashCount: Int = 0
    ) -> GitRepoState {
        GitRepoState(
            root: root,
            branch: branch,
            detachedHead: branch == nil ? "abc1234" : nil,
            upstream: upstream,
            staged: staged,
            unstaged: unstaged,
            stashCount: stashCount
        )
    }

    @Test func fixedCommandLines() throws {
        let s = state(upstream: "origin/main")
        #expect(try GitActions.fetch.commandLine(for: s) == "git fetch --all --prune")
        #expect(try GitActions.pull.commandLine(for: s) == "git pull --ff-only")
        #expect(try GitActions.push.commandLine(for: s) == "git push")
        #expect(try GitActions.stashPush.commandLine(for: s) == "git stash push")
        #expect(try GitActions.stashPop.commandLine(for: s) == "git stash pop")
    }

    @Test func pushWithoutUpstreamSetsUpstreamWithQuotedBranch() throws {
        #expect(try GitActions.push.commandLine(for: state(branch: "feature/x")) == "git push -u origin feature/x")
        #expect(try GitActions.push.commandLine(for: state(branch: "feat x")) == "git push -u origin 'feat x'")
    }

    @Test func pushOnDetachedHeadThrows() {
        #expect(throws: GitAction.CommandError.detachedHead) {
            try GitActions.push.commandLine(for: state(branch: nil))
        }
    }

    @Test func switchAndCreateQuoteBranchNames() throws {
        let s = state()
        #expect(try GitActions.switchBranch(to: "release/1.0").commandLine(for: s) == "git switch release/1.0")
        #expect(try GitActions.switchBranch(to: "it's").commandLine(for: s) == "git switch 'it'\\''s'")
        #expect(try GitActions.createBranch(named: "new branch").commandLine(for: s) == "git switch -c 'new branch'")
    }

    @Test func switchRejectsUnsafeNames() {
        #expect(throws: GitAction.CommandError.invalidName(.leadingDash)) {
            try GitActions.switchBranch(to: "-D").commandLine(for: state())
        }
        #expect(throws: GitAction.CommandError.invalidName(.containsControlCharacters)) {
            try GitActions.switchBranch(to: "main\nrm -rf ~").commandLine(for: state())
        }
        #expect(throws: GitAction.CommandError.invalidName(.empty)) {
            try GitActions.createBranch(named: "").commandLine(for: state())
        }
    }

    @Test func availability() {
        let clean = state()
        #expect(GitActions.fetch.isAvailable(for: clean))
        #expect(!GitActions.pull.isAvailable(for: clean))
        #expect(GitActions.push.isAvailable(for: clean))
        #expect(!GitActions.stashPush.isAvailable(for: clean))
        #expect(!GitActions.stashPop.isAvailable(for: clean))

        let busy = state(upstream: "origin/main", unstaged: 2, stashCount: 1)
        #expect(GitActions.pull.isAvailable(for: busy))
        #expect(GitActions.stashPush.isAvailable(for: busy))
        #expect(GitActions.stashPop.isAvailable(for: busy))
        #expect(GitActions.available(for: busy).map(\.kind) == [.fetch, .pull, .push, .stashPush, .stashPop])

        let detached = state(branch: nil)
        #expect(!GitActions.push.isAvailable(for: detached))
        #expect(!GitActions.switchBranch(to: "main").isAvailable(for: clean))
        #expect(GitActions.switchBranch(to: "other").isAvailable(for: clean))
    }

    @Test func actionIdentityIncludesArgument() {
        #expect(GitActions.switchBranch(to: "a").id != GitActions.switchBranch(to: "b").id)
        #expect(GitActions.fetch.id == "fetch")
    }
}

struct GitRepoStateCodableTests {
    @Test func roundTripsThroughJSONWithPortableKeys() throws {
        let original = GitRepoState(
            root: URL(fileURLWithPath: "/Users/me/Dev/repo", isDirectory: true),
            branch: nil,
            detachedHead: "abc1234",
            upstream: "origin/main",
            ahead: 1,
            behind: 2,
            staged: 3,
            unstaged: 4,
            untracked: 5,
            conflicted: 6,
            stashCount: 7,
            operation: .cherryPick,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["root"] as? String == "/Users/me/Dev/repo")
        #expect(json["operation"] as? String == "cherry-pick")
        #expect(json["updatedAt"] as? Double == 1_700_000_000)
        #expect(json["branch"] == nil)

        let decoded = try JSONDecoder().decode(GitRepoState.self, from: data)
        #expect(decoded == original)
        #expect(decoded.isDetached)
        #expect(decoded.headLabel == "abc1234")
        #expect(decoded.isDirty)
    }

    @Test func decodesMinimalDocumentWithDefaults() throws {
        let data = Data(#"{"root":"/tmp/x","branch":"main"}"#.utf8)
        let state = try JSONDecoder().decode(GitRepoState.self, from: data)
        #expect(state.branch == "main")
        #expect(state.staged == 0)
        #expect(state.stashCount == 0)
        #expect(state.operation == nil)
        #expect(!state.isDirty)
        #expect(state.headLabel == "main")
    }
}
