import Testing
import Foundation
@testable import Ghostty

struct GitBranchRefTests {
    @Test func localsThenRemotesWithoutDuplicates() {
        let refs = [
            "refs/heads/main",
            "refs/heads/feature/x",
            "refs/remotes/origin/HEAD",
            "refs/remotes/origin/main",
            "refs/remotes/origin/topic",
            "refs/remotes/upstream/topic",
        ]
        let list = GitBranchRef.list(fromRefNames: refs)
        #expect(list.map(\.name) == ["main", "feature/x", "origin/topic"])
        #expect(list.map(\.switchName) == ["main", "feature/x", "topic"])
        #expect(list.map(\.isRemote) == [false, false, true])
    }

    @Test func dropsUnsafeNames() {
        let refs = ["refs/heads/-evil", "refs/heads/ok", "refs/remotes/origin/a\u{202e}b"]
        #expect(GitBranchRef.list(fromRefNames: refs).map(\.name) == ["ok"])
    }
}
