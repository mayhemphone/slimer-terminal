import Testing
import Foundation
@testable import Ghostty

struct StatusBarPathAbbreviationTests {
    let home = "/Users/me"

    @Test func homeBecomesTilde() {
        #expect(StatusBarFormatting.abbreviate(path: "/Users/me", home: home) == "~")
        #expect(StatusBarFormatting.abbreviate(path: "/Users/me/", home: home) == "~")
    }

    @Test func pathsUnderHomeUseTilde() {
        #expect(StatusBarFormatting.abbreviate(path: "/Users/me/Dev/slimer", home: home) == "~/Dev/slimer")
    }

    @Test func siblingWithHomePrefixIsNotAbbreviated() {
        #expect(StatusBarFormatting.abbreviate(path: "/Users/meme/x", home: home) == "/Users/meme/x")
    }

    @Test func deepPathsKeepLastComponents() {
        #expect(StatusBarFormatting.abbreviate(path: "/Users/me/a/b/c/d", home: home) == "~/…/b/c/d")
        #expect(StatusBarFormatting.abbreviate(path: "/usr/local/share/man/man1", home: home) == "/…/share/man/man1")
        #expect(StatusBarFormatting.abbreviate(path: "/usr/local/share", home: home) == "/usr/local/share")
    }

    @Test func rootStaysRoot() {
        #expect(StatusBarFormatting.abbreviate(path: "/", home: home) == "/")
    }

    @Test func rootHomeIsNotTreatedAsHome() {
        #expect(StatusBarFormatting.abbreviate(path: "/etc", home: "/") == "/etc")
    }
}

struct StatusBarUserHostTests {
    @Test(arguments: [
        ("me@mac", "me@mac"),
        ("me@mac: ~/Dev", "me@mac"),
        ("me@mac:~/Dev", "me@mac"),
        ("me@mac ~/Dev", "me@mac"),
        ("first.last@host-1.example.com: /tmp", "first.last@host-1.example.com"),
    ])
    func parsesShellTitles(title: String, expected: String) {
        #expect(StatusBarFormatting.userHost(fromTitle: title) == expected)
    }

    @Test(arguments: [
        "",
        "vim README.md",
        "~/Dev/slimer",
        "@host",
        "me@",
        "me@-host",
        "me@host/path",
        "git push origin me@host",
        "me@host\u{1b}]0;evil",
        "✳ Claude Code",
    ])
    func rejectsOtherTitles(title: String) {
        #expect(StatusBarFormatting.userHost(fromTitle: title) == nil)
    }

    @Test func rejectsOverlongTitles() {
        let title = "me@host: " + String(repeating: "x", count: 300)
        #expect(StatusBarFormatting.userHost(fromTitle: title) == nil)
    }
}

struct StatusBarDurationTests {
    @Test func formatsDurations() {
        #expect(StatusBarFormatting.duration(nanoseconds: 420_000_000) == "420ms")
        #expect(StatusBarFormatting.duration(nanoseconds: 3_250_000_000) == "3.2s")
        #expect(StatusBarFormatting.duration(nanoseconds: 42_000_000_000) == "42s")
        #expect(StatusBarFormatting.duration(nanoseconds: 252_000_000_000) == "4m 12s")
        #expect(StatusBarFormatting.duration(nanoseconds: 3_780_000_000_000) == "1h 3m")
    }
}
