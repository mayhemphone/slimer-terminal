import Testing
import Foundation
@testable import Ghostty

struct GitHubRemoteTests {
    @Test(arguments: [
        "https://github.com/ghostty-org/ghostty.git",
        "https://github.com/ghostty-org/ghostty",
        "https://github.com/ghostty-org/ghostty/",
        "https://user@github.com/ghostty-org/ghostty.git",
        "https://GitHub.com/ghostty-org/ghostty.git",
        "git@github.com:ghostty-org/ghostty.git",
        "git@github.com:ghostty-org/ghostty",
        "ssh://git@github.com/ghostty-org/ghostty.git",
        "ssh://git@github.com:22/ghostty-org/ghostty.git",
        "  https://github.com/ghostty-org/ghostty.git\n",
    ])
    func parsesGitHubRemotes(url: String) throws {
        let remote = try #require(GitHubRemote(remoteURL: url))
        #expect(remote.owner == "ghostty-org")
        #expect(remote.repo == "ghostty")
    }

    @Test func keepsDotsInRepoNames() throws {
        let remote = try #require(GitHubRemote(remoteURL: "git@github.com:me/my.site.git"))
        #expect(remote.repo == "my.site")
    }

    @Test(arguments: [
        "",
        "http://github.com/a/b.git",
        "git://github.com/a/b.git",
        "file:///Users/me/repo",
        "/Users/me/repo",
        "https://gitlab.com/a/b.git",
        "https://github.com.evil.com/a/b.git",
        "https://evil.com/github.com/a/b.git",
        "git@gitlab.com:a/b.git",
        "evil@github.com:a/b.git",
        "ssh://root@github.com/a/b.git",
        "https://github.com/a",
        "https://github.com/a/b/c",
        "https://github.com/a/..",
        "https://github.com/-a/b",
        "https://github.com/a b/c",
        "https://github.com/a/b?x=1",
        "https://github.com/a/b#frag",
        "https://github.com:8443/a/b",
    ])
    func rejectsOtherRemotes(url: String) {
        #expect(GitHubRemote(remoteURL: url) == nil)
    }

    @Test func repositoryURL() throws {
        let remote = try #require(GitHubRemote(owner: "me", repo: "slimer"))
        #expect(remote.repositoryURL?.absoluteString == "https://github.com/me/slimer")
    }

    @Test func pullRequestURLKeepsSlashes() throws {
        let remote = try #require(GitHubRemote(owner: "me", repo: "slimer"))
        #expect(remote.newPullRequestURL(branch: "feature/status-bar")?.absoluteString
            == "https://github.com/me/slimer/pull/new/feature/status-bar")
    }

    @Test func pullRequestURLPercentEncodesBranch() throws {
        let remote = try #require(GitHubRemote(owner: "me", repo: "slimer"))
        #expect(remote.newPullRequestURL(branch: "fix#1 é?x=1")?.absoluteString
            == "https://github.com/me/slimer/pull/new/fix%231%20%C3%A9%3Fx%3D1")
        #expect(remote.newPullRequestURL(branch: "a%2Fb")?.absoluteString
            == "https://github.com/me/slimer/pull/new/a%252Fb")
    }

    @Test(arguments: ["", "-x", "a/../b", "a//b", "../x", "a\nb"])
    func pullRequestURLRejectsUnsafeBranches(branch: String) throws {
        let remote = try #require(GitHubRemote(owner: "me", repo: "slimer"))
        #expect(remote.newPullRequestURL(branch: branch) == nil)
    }
}
