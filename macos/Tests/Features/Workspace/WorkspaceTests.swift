//
//  WorkspaceTests.swift
//  GhosttyTests
//
//  Slimer: tests for the Workspace feature (workspace.json models, store,
//  shell quoting, shortcuts, frecency and path expansion).
//

import Combine
import XCTest
@testable import Ghostty

// MARK: - Models and JSON

final class WorkspaceModelTests: XCTestCase {
    func testJSONRoundTrip() throws {
        let original = WorkspaceDocument(
            locations: [
                WorkspaceLocation(
                    name: "Backend",
                    path: "~/Dev/league-view-backend",
                    icon: "server.rack",
                    color: "#FF8800",
                    pinned: true,
                    shortcut: "cmd+shift+1",
                    startupCommand: "claude"
                ),
            ],
            commands: [
                WorkspaceCommand(
                    name: "Status",
                    command: "git status",
                    cwd: "~/Dev",
                    pinned: false,
                    shortcut: "cmd+shift+g",
                    confirm: false
                ),
            ]
        )

        let data = try original.encoded()
        let decoded = try WorkspaceDocument.decode(data)
        XCTAssertEqual(decoded, original)

        // Human-friendly on disk: pretty printed, unescaped slashes. Usage and
        // recent directories are per machine and never written here.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"path\" : \"~/Dev/league-view-backend\""), text)
        XCTAssertFalse(text.contains("useCount"), text)
        XCTAssertFalse(text.contains("recent"), text)
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testTolerantParsingIgnoresUnknownKeysAndDefaultsMissingOnes() throws {
        let json = """
        {
          "version": 1,
          "somethingNew": {"nested": true},
          "locations": [
            {"path": "~/Dev", "futureField": 42},
            {"name": "Bad", "icon": "x"},
            "not an object",
            {"path": "~/Dev/other", "pinned": "yes", "useCount": "many", "lastUsed": "garbage"}
          ],
          "commands": [
            {"command": "claude"},
            {"name": "no command here"}
          ],
          "recent": [
            {"path": "/Users/me", "count": 2, "lastVisited": 1700000000}
          ]
        }
        """
        let doc = try WorkspaceDocument.decode(Data(json.utf8))

        XCTAssertEqual(doc.locations.count, 2)
        XCTAssertEqual(doc.locations[0].path, "~/Dev")
        XCTAssertEqual(doc.locations[0].name, "Dev") // derived from the path
        XCTAssertFalse(doc.locations[0].pinned)
        XCTAssertEqual(doc.locations[1].path, "~/Dev/other")
        XCTAssertFalse(doc.locations[1].pinned) // wrong type -> default
        XCTAssertNil(doc.locations[1].legacyUsage)
        // Entries without a path/command are kept, not used.
        XCTAssertEqual(doc.unusableLocations.map(\.index), [1, 2])
        XCTAssertEqual(doc.unusableCommands.map(\.index), [1])

        XCTAssertEqual(doc.commands.count, 1)
        XCTAssertEqual(doc.commands[0].name, "claude")
        XCTAssertTrue(doc.commands[0].confirm) // default is true

        XCTAssertEqual(doc.legacyRecent.count, 1)
        XCTAssertEqual(doc.legacyRecent[0].lastVisited, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testTolerantParsingOfMissingSections() throws {
        let doc = try WorkspaceDocument.decode(Data("{}".utf8))
        XCTAssertEqual(doc.version, WorkspaceDocument.currentVersion)
        XCTAssertTrue(doc.locations.isEmpty)
        XCTAssertTrue(doc.commands.isEmpty)
        XCTAssertTrue(doc.legacyRecent.isEmpty)
    }

    func testGarbageFails() {
        XCTAssertThrowsError(try WorkspaceDocument.decode(Data("{ not json".utf8)))
        XCTAssertThrowsError(try WorkspaceDocument.decode(Data("[]".utf8)))
    }

    func testSeedContents() {
        let seed = WorkspaceDocument.seed()
        XCTAssertEqual(seed.locations.map(\.path), ["~", "~/Dev", "~/Dev/league-view-backend"])
        XCTAssertEqual(seed.commands.map(\.command), ["claude", "claude --continue", "git status"])
        XCTAssertTrue(seed.commands.allSatisfy(\.confirm))
    }
}

// MARK: - Frecency

final class WorkspaceFrecencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecentOrderingPrefersRecentAndFrequent() {
        var doc = WorkspaceRecentDocument()
        // Old but frequent.
        for _ in 0..<10 { doc.recordVisit(path: "/old-frequent", now: now.addingTimeInterval(-30 * 86_400)) }
        // Recent and moderately frequent.
        for _ in 0..<3 { doc.recordVisit(path: "/fresh", now: now.addingTimeInterval(-60)) }
        // Yesterday, once.
        doc.recordVisit(path: "/yesterday", now: now.addingTimeInterval(-2 * 3600))

        let ranked = doc.rankedRecent(now: now).map(\.path)
        XCTAssertEqual(ranked, ["/fresh", "/old-frequent", "/yesterday"])

        // Counts accumulate on the same path.
        XCTAssertEqual(doc.recent.first { $0.path == "/old-frequent" }?.count, 10)
    }

    func testRecentIsCappedAtLimitKeepingBestScores() {
        var doc = WorkspaceRecentDocument()
        // Visits arrive in chronological order. One hot directory visited many
        // times a long time ago must survive the flood of one-off visits below.
        for _ in 0..<50 { doc.recordVisit(path: "/hot", now: now.addingTimeInterval(-50 * 86_400)) }
        for i in 0..<(WorkspaceFrecency.recentLimit + 20) {
            // Older entries first; each later entry is fresher.
            doc.recordVisit(path: "/dir\(i)", now: now.addingTimeInterval(TimeInterval(-100_000 + i * 60)))
        }

        XCTAssertEqual(doc.recent.count, WorkspaceFrecency.recentLimit)
        XCTAssertTrue(doc.recent.contains { $0.path == "/hot" })
        XCTAssertFalse(doc.recent.contains { $0.path == "/dir0" })
        XCTAssertTrue(doc.recent.contains { $0.path == "/dir\(WorkspaceFrecency.recentLimit + 19)" })
    }

    func testJustVisitedDirectoryIsNeverEvicted() {
        var doc = WorkspaceRecentDocument()
        for i in 0..<WorkspaceFrecency.recentLimit {
            for _ in 0..<20 { doc.recordVisit(path: "/busy\(i)", now: now) }
        }
        doc.recordVisit(path: "/brand-new", now: now.addingTimeInterval(-40 * 86_400))
        XCTAssertEqual(doc.recent.count, WorkspaceFrecency.recentLimit)
        XCTAssertTrue(doc.recent.contains { $0.path == "/brand-new" })
    }

    func testLocationsPinnedFirstThenFrecencyThenName() {
        let doc = WorkspaceDocument(locations: [
            WorkspaceLocation(name: "zeta", path: "/z"),
            WorkspaceLocation(name: "alpha", path: "/a"),
            WorkspaceLocation(name: "pinned", path: "/p", pinned: true),
            WorkspaceLocation(name: "used", path: "/u"),
        ])
        var usage = WorkspaceUsageDocument()
        usage.recordUse(id: doc.locations[3].id, seed: nil, now: now.addingTimeInterval(-10))

        XCTAssertEqual(doc.rankedLocations(usage: usage, now: now).map(\.name), ["pinned", "used", "alpha", "zeta"])
    }

    func testCommandsPinnedFirstThenFrecency() {
        let doc = WorkspaceDocument(commands: [
            WorkspaceCommand(name: "b", command: "b"),
            WorkspaceCommand(name: "a", command: "a"),
            WorkspaceCommand(name: "p", command: "p", pinned: true),
        ])
        var usage = WorkspaceUsageDocument()
        usage.recordUse(id: doc.commands[0].id, seed: nil, now: now)
        XCTAssertEqual(doc.rankedCommands(usage: usage, now: now).map(\.name), ["p", "b", "a"])
    }

    func testLegacyUsageSeedsLocalStatistics() throws {
        let json = #"{"commands":[{"id":"0F0E4A2E-0B3F-4D3F-8C6B-2A4C9B1D7E22","command":"a","useCount":5,"lastUsed":"2026-10-28T14:03:11Z"},{"command":"b"}]}"#
        let doc = try WorkspaceDocument.decode(Data(json.utf8))
        let seeded = try XCTUnwrap(doc.commands[0].legacyUsage)
        XCTAssertEqual(seeded.count, 5)
        // Ranked by the seed until used on this machine.
        XCTAssertEqual(doc.rankedCommands(now: now).map(\.name), ["a", "b"])

        var usage = WorkspaceUsageDocument()
        usage.recordUse(id: doc.commands[0].id, seed: seeded, now: now)
        XCTAssertEqual(usage.entries[doc.commands[0].id]?.count, 6)
        XCTAssertEqual(usage.entries[doc.commands[0].id]?.lastUsed, now)
        // usage.json round trip.
        let reread = WorkspaceUsageDocument(json: try JSONValue.decode(usage.json.encodedFile()))
        XCTAssertEqual(reread, usage)
    }

    func testScoreWeights() {
        XCTAssertEqual(WorkspaceFrecency.score(count: 1, last: now.addingTimeInterval(-10), now: now), 4)
        XCTAssertEqual(WorkspaceFrecency.score(count: 1, last: now.addingTimeInterval(-7200), now: now), 2)
        XCTAssertEqual(WorkspaceFrecency.score(count: 2, last: now.addingTimeInterval(-3 * 86_400), now: now), 1)
        XCTAssertEqual(WorkspaceFrecency.score(count: 4, last: now.addingTimeInterval(-30 * 86_400), now: now), 1)
        XCTAssertEqual(WorkspaceFrecency.score(count: 4, last: nil, now: now), 0)
    }
}

// MARK: - Shell quoting and safety

final class WorkspaceShellTests: XCTestCase {
    func testQuoteAlwaysSingleQuotes() {
        XCTAssertEqual(WorkspaceShell.quote("simple"), "'simple'")
        XCTAssertEqual(WorkspaceShell.quote("/Users/me/My Dev"), "'/Users/me/My Dev'")
        XCTAssertEqual(WorkspaceShell.quote("$HOME;rm -rf *"), "'$HOME;rm -rf *'")
        XCTAssertEqual(WorkspaceShell.quote(""), "''")
    }

    func testQuoteEscapesEmbeddedSingleQuotes() {
        XCTAssertEqual(WorkspaceShell.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(WorkspaceShell.quote("'"), "''\\'''")
    }

    func testCdCommand() {
        XCTAssertEqual(WorkspaceShell.cdCommand(to: "/Users/me/Dev"), "cd '/Users/me/Dev'")
    }

    func testTextBindingActionEscapesBackslashesAndAppendsEnter() {
        XCTAssertEqual(WorkspaceShell.textBindingAction("cd 'a'", pressEnter: true), "text:cd 'a'\\r")
        XCTAssertEqual(WorkspaceShell.textBindingAction("echo a\\b", pressEnter: false), "text:echo a\\\\b")
    }

    func testTypedPathsRejectQuotesAndBackslashes() {
        // fish treats \' and \\ as escapes inside single quotes; such a path
        // must never be typed.
        let evil = "/Users/me/a\\'; touch PWNED #"
        XCTAssertFalse(WorkspaceShell.isSafeToType(path: evil))
        XCTAssertFalse(WorkspaceShell.isSafeToType(path: "/Users/me/back\\slash"))
        XCTAssertFalse(WorkspaceShell.isSafeToType(path: "/Users/me/it's"))
        XCTAssertFalse(WorkspaceShell.isSafeToType(path: "/Users/me/x\u{202E}y"))
        XCTAssertTrue(WorkspaceShell.isSafeToType(path: "/Users/me/My Dev (2) $HOME;*"))
        // Still a fine working_directory (no shell involved).
        XCTAssertTrue(WorkspaceShell.isSafeToInsert(evil))
    }

    func testTextBindingActionNeverClearsTheLine() {
        // No Ctrl-U (or any other line-kill key) is ever sent.
        XCTAssertEqual(WorkspaceShell.textBindingAction("cd '/a'", pressEnter: true), "text:cd '/a'\\r")
        XCTAssertFalse(WorkspaceShell.textBindingAction("git status", pressEnter: false).contains("x15"))
    }

    func testIsSafeToInsertRejectsFormatCharacters() {
        let scalars: [Character] = ["\u{200E}", "\u{200F}", "\u{061C}", "\u{FEFF}", "\u{200B}", "\u{200D}", "\u{00AD}", "\u{E0041}"]
        for scalar in scalars {
            XCTAssertFalse(WorkspaceShell.isSafeToInsert("a\(scalar)b"), "should reject \(scalar.unicodeScalars.first!.value)")
        }
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("x\u{2029}y"))
    }

    func testIsSafeToInsertRejectsControlAndBidi() {
        XCTAssertTrue(WorkspaceShell.isSafeToInsert("git status"))
        XCTAssertTrue(WorkspaceShell.isSafeToInsert("cd '/Users/me/Ünïcödé 日本'"))
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("ls\n"))
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("ls\r"))
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("a\tb"))
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("\u{1B}[2J"))
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("x\u{7F}"))
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("x\u{85}"))
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("x\u{2028}y"))
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("x\u{202E}y")) // RLO
        XCTAssertFalse(WorkspaceShell.isSafeToInsert("x\u{2066}y")) // LRI
    }
}

// MARK: - Paths

final class WorkspacePathTests: XCTestCase {
    private let home = "/Users/tester"

    func testTildeExpansion() {
        XCTAssertEqual(WorkspacePath.expand("~", home: home), "/Users/tester")
        XCTAssertEqual(WorkspacePath.expand("~/Dev", home: home), "/Users/tester/Dev")
        XCTAssertEqual(WorkspacePath.expand("~/Dev/", home: home), "/Users/tester/Dev")
        XCTAssertEqual(WorkspacePath.expand(" ~/Dev ", home: home), "/Users/tester/Dev")
        XCTAssertEqual(WorkspacePath.expand("/opt/x", home: home), "/opt/x")
        XCTAssertEqual(WorkspacePath.expand("/", home: home), "/")
        // "~user" forms are not expanded.
        XCTAssertEqual(WorkspacePath.expand("~other/x", home: home), "~other/x")
    }

    func testAbbreviateAndDisplayName() {
        XCTAssertEqual(WorkspacePath.abbreviate("/Users/tester", home: home), "~")
        XCTAssertEqual(WorkspacePath.abbreviate("/Users/tester/Dev", home: home), "~/Dev")
        XCTAssertEqual(WorkspacePath.abbreviate("/Users/testerx/Dev", home: home), "/Users/testerx/Dev")
        XCTAssertEqual(WorkspacePath.displayName(for: "~", home: home), "~")
        XCTAssertEqual(WorkspacePath.displayName(for: "~/Dev/league-view-backend", home: home), "league-view-backend")
    }

    func testConfigDirectoryHonorsXDG() {
        XCTAssertEqual(
            WorkspacePath.defaultFileURL(environment: [:], home: home).path,
            "/Users/tester/.config/slimer/workspace.json"
        )
        XCTAssertEqual(
            WorkspacePath.defaultFileURL(environment: ["XDG_CONFIG_HOME": "/xdg"], home: home).path,
            "/xdg/slimer/workspace.json"
        )
        // Relative XDG_CONFIG_HOME is ignored per the spec.
        XCTAssertEqual(
            WorkspacePath.defaultFileURL(environment: ["XDG_CONFIG_HOME": "relative"], home: home).path,
            "/Users/tester/.config/slimer/workspace.json"
        )
    }

    func testRecordableFiltersScratchPaths() {
        XCTAssertTrue(WorkspacePath.isRecordable("/Users/tester/Dev"))
        XCTAssertFalse(WorkspacePath.isRecordable("/"))
        XCTAssertFalse(WorkspacePath.isRecordable("/tmp"))
        XCTAssertFalse(WorkspacePath.isRecordable("/tmp/x"))
        XCTAssertFalse(WorkspacePath.isRecordable("/private/tmp/x"))
        XCTAssertTrue(WorkspacePath.isRecordable("/tmpfoo"))
        XCTAssertFalse(WorkspacePath.isRecordable("relative"))
        XCTAssertFalse(WorkspacePath.isRecordable("~/Dev"))
        XCTAssertFalse(WorkspacePath.isRecordable("/Volumes/USB/x"))
        XCTAssertFalse(WorkspacePath.isRecordable("/net/host/share"))
        XCTAssertFalse(WorkspacePath.isRecordable("/Network/Servers/x"))
        XCTAssertTrue(WorkspacePath.isRecordable("/Volumesque"))
        XCTAssertFalse(WorkspacePath.isRecordable("/" + String(repeating: "a", count: 1024)))
        XCTAssertTrue(WorkspacePath.isRecordable("/" + String(repeating: "a", count: 1000)))
        XCTAssertFalse(WorkspacePath.isRecordable("/Users/me/evil\u{202E}dir"))
        XCTAssertFalse(WorkspacePath.isRecordable("/Users/me/new\nline"))
    }

    func testXCTestUsesThrowawayFile() {
        XCTAssertTrue(WorkspacePath.isRunningUnderXCTest())
        let url = WorkspacePath.defaultFileURL(environment: ["XCTestConfigurationFilePath": "/x"], home: home)
        XCTAssertTrue(url.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).path), url.path)
        XCTAssertFalse(url.path.contains("/.config/slimer"))
        // The test host app's own store is not on the real file either.
        XCTAssertFalse(WorkspaceStore.shared.fileURL.path.contains("/.config/slimer/"))
    }
}

// MARK: - Shortcuts

final class WorkspaceShortcutTests: XCTestCase {
    func testParsesModifiersAndKeys() throws {
        let s = try XCTUnwrap(WorkspaceShortcut(parsing: "cmd+shift+1"))
        XCTAssertEqual(s.keyEquivalent, "1")
        XCTAssertEqual(s.modifiers, [.command, .shift])
        XCTAssertEqual(s.symbols, ["⇧", "⌘", "1"])

        let e = try XCTUnwrap(WorkspaceShortcut(parsing: "ctrl+alt+enter"))
        XCTAssertEqual(e.keyEquivalent, "\r")
        XCTAssertEqual(e.modifiers, [.control, .option])

        let f = try XCTUnwrap(WorkspaceShortcut(parsing: "super+F5"))
        XCTAssertEqual(f.symbols, ["⌘", "F5"])

        let letter = try XCTUnwrap(WorkspaceShortcut(parsing: "Cmd+Opt+G"))
        XCTAssertEqual(letter.keyEquivalent, "g")
        XCTAssertEqual(letter.modifiers, [.command, .option])
    }

    func testRejectsInvalid() {
        XCTAssertNil(WorkspaceShortcut(parsing: ""))
        XCTAssertNil(WorkspaceShortcut(parsing: "cmd+shift"))
        XCTAssertNil(WorkspaceShortcut(parsing: "cmd+a+b"))
        XCTAssertNil(WorkspaceShortcut(parsing: "cmd+nosuchkey"))
    }
}

final class WorkspaceShortcutPolicyTests: XCTestCase {
    func testRequiresCommand() {
        XCTAssertNil(WorkspaceShortcut.accepted("ctrl+1", log: false) { _ in false })
        XCTAssertNil(WorkspaceShortcut.accepted("alt+shift+g", log: false) { _ in false })
        XCTAssertNil(WorkspaceShortcut.accepted("f5", log: false) { _ in false })
        XCTAssertNil(WorkspaceShortcut.accepted(nil, log: false) { _ in false })
        XCTAssertNil(WorkspaceShortcut.accepted("  ", log: false) { _ in false })
        XCTAssertNotNil(WorkspaceShortcut.accepted("cmd+shift+1", log: false) { _ in false })
    }

    func testRejectsExistingGhosttyBinding() {
        var asked: [WorkspaceShortcut] = []
        let result = WorkspaceShortcut.accepted("cmd+t", log: false) { shortcut in
            asked.append(shortcut)
            return true
        }
        XCTAssertNil(result)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.ghosttyKey, "t")
    }

    func testGhosttyKeyMapping() throws {
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+shift+1")?.ghosttyKey, "digit1")
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+one")?.ghosttyKey, "digit1")
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+a")?.ghosttyKey, "a")
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+a")?.unshiftedCodepoint, 0x61)
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+enter")?.ghosttyKey, "enter")
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+enter")?.unshiftedCodepoint, 0)
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+comma")?.ghosttyKey, "comma")
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+[")?.ghosttyKey, "bracketLeft")
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+f12")?.ghosttyKey, "f12")
        XCTAssertEqual(WorkspaceShortcut(parsing: "cmd+up")?.ghosttyKey, "arrowUp")
        // Every mapped key is a real Ghostty key.
        for spec in ["cmd+shift+1", "cmd+a", "cmd+enter", "cmd+comma", "cmd+[", "cmd+f12", "cmd+up", "cmd+page_down", "cmd+`"] {
            let key = try XCTUnwrap(WorkspaceShortcut(parsing: spec)?.ghosttyKey, spec)
            XCTAssertNotNil(Ghostty.Input.Key(rawValue: key), spec)
        }
    }

    func testAlternateModifiers() throws {
        let base = try XCTUnwrap(WorkspaceShortcut(parsing: "cmd+shift+1"))
        let alt = base.with(modifiers: base.modifiers.union(.option))
        XCTAssertEqual(alt.keyEquivalent, "1")
        XCTAssertEqual(alt.modifiers, [.command, .shift, .option])
        XCTAssertEqual(alt.ghosttyKey, "digit1")
        XCTAssertNotEqual(alt, base)
    }
}

final class WorkspaceDisplayTests: XCTestCase {
    func testCommandTitleShowsHiddenCommandText() {
        XCTAssertEqual(WorkspaceDisplay.commandTitle(WorkspaceCommand(name: "Claude", command: "claude")), "Claude")
        XCTAssertEqual(
            WorkspaceDisplay.commandTitle(WorkspaceCommand(name: "git status", command: "git status --short")),
            "git status"
        )
        XCTAssertEqual(
            WorkspaceDisplay.commandTitle(WorkspaceCommand(name: "Deploy", command: "rm -rf ~")),
            "Deploy — rm -rf ~"
        )
        let long = String(repeating: "x", count: 100)
        let title = WorkspaceDisplay.commandTitle(WorkspaceCommand(name: "Long", command: long))
        XCTAssertEqual(title, "Long — " + String(repeating: "x", count: 59) + "…")
    }

    func testAutoRunMarker() {
        XCTAssertEqual(
            WorkspaceDisplay.commandTitle(WorkspaceCommand(name: "Status", command: "git status", confirm: false)),
            "Status — git status ⏎"
        )
        let auto = WorkspaceLocation(name: "Dev", path: "/dev", startupCommand: "claude", startupConfirm: false)
        XCTAssertEqual(WorkspaceDisplay.locationTitle(auto), "Dev ⏎")
        XCTAssertTrue(WorkspaceDisplay.locationDetail(auto).hasSuffix("→ claude ⏎"))

        let gated = WorkspaceLocation(name: "Dev", path: "/dev", startupCommand: "claude")
        XCTAssertEqual(WorkspaceDisplay.locationTitle(gated), "Dev")
        XCTAssertEqual(WorkspaceDisplay.locationDetail(gated), "/dev  → claude")
        XCTAssertEqual(WorkspaceDisplay.locationDetail(WorkspaceLocation(name: "Dev", path: "/dev")), "/dev")
    }
}

final class WorkspaceStartupTests: XCTestCase {
    func testStartupConfirmDefaultsTrueAndRoundTrips() throws {
        let doc = try WorkspaceDocument.decode(Data(#"{"locations":[{"path":"/x","startupCommand":"claude"}]}"#.utf8))
        XCTAssertEqual(doc.locations.first?.startupConfirm, true)
        var changed = doc
        changed.locations[0].startupConfirm = false
        XCTAssertEqual(try WorkspaceDocument.decode(changed.encoded()).locations.first?.startupConfirm, false)
    }

    func testStartupCommandIsTypedWithoutEnterUnlessOptedOut() {
        let gated = WorkspaceActions.surfaceConfiguration(path: "/x", startup: ("claude", true))
        XCTAssertEqual(gated.workingDirectory, "/x")
        XCTAssertEqual(gated.initialInput, "claude")

        let auto = WorkspaceActions.surfaceConfiguration(path: "/x", startup: ("claude", false))
        XCTAssertEqual(auto.initialInput, "claude\n")

        // An untypeable path is still fine as a working directory.
        let none = WorkspaceActions.surfaceConfiguration(path: "/a\\'b", startup: nil)
        XCTAssertEqual(none.workingDirectory, "/a\\'b")
        XCTAssertNil(none.initialInput)
    }
}

// MARK: - Store (disk)

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!
    private var localDirectory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("sub/workspace.json")
        localDirectory = directory.appendingPathComponent("local", isDirectory: true)
    }

    private func makeStore(
        watch: Bool = false,
        visitDebounce: TimeInterval = 1.5,
        now: @escaping () -> Date = Date.init
    ) -> WorkspaceStore {
        WorkspaceStore(fileURL: fileURL, localDirectory: localDirectory, watch: watch, visitDebounce: visitDebounce, now: now)
    }

    private func writeFile(_ json: String) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: fileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? Int)
    }

    func testFirstRunSeedsFileWithRestrictedPermissions() throws {
        let store = makeStore()
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.document.locations.map(\.path), ["~", "~/Dev", "~/Dev/league-view-backend"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try permissions(of: fileURL) & 0o777, 0o600)
        XCTAssertEqual(try permissions(of: fileURL.deletingLastPathComponent()) & 0o777, 0o700)

        // No leftover temp files from the atomic write.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["workspace.json"])

        // A second store reads the same document back.
        let again = makeStore()
        XCTAssertEqual(again.document, store.document)
    }

    func testInvalidFileIsKeptInMemoryAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: fileURL)

        let store = makeStore()
        XCTAssertNotNil(store.loadError)
        XCTAssertTrue(store.document.locations.isEmpty)

        // Usage recording must not clobber the user's broken file.
        store.commitVisit(NSHomeDirectory())
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage)

        // Once the file is fixed, a reload picks it up and saving resumes.
        try Data(#"{"locations":[{"name":"Fixed","path":"~"}]}"#.utf8).write(to: fileURL)
        store.reload()
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.document.locations.map(\.name), ["Fixed"])
    }

    func testRecordUseAndVisitPersist() throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore(now: { clock })
        let location = store.document.locations[1] // ~/Dev
        store.recordUse(location: location)
        clock = clock.addingTimeInterval(120)
        store.recordUse(location: location)

        let reloaded = makeStore()
        let saved = try XCTUnwrap(reloaded.usage.entries[location.id])
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.lastUsed, clock)
        // Using a location also counts as visiting its directory.
        XCTAssertTrue(reloaded.recent.recent.contains { $0.path == location.expandedPath })

        // Existence is checked (off the main thread) before committing.
        XCTAssertFalse(WorkspaceStore.directoryExists("/definitely/not/a/real/dir"))
        XCTAssertTrue(WorkspaceStore.directoryExists(NSHomeDirectory()))

        // Visits are counted once per minute.
        let home = NSHomeDirectory()
        store.commitVisit(home)
        store.commitVisit(home)
        XCTAssertEqual(store.recent.recent.first { $0.path == home }?.count, 1)
        clock = clock.addingTimeInterval(61)
        store.commitVisit(home)
        XCTAssertEqual(store.recent.recent.first { $0.path == home }?.count, 2)

        let persisted = makeStore()
        XCTAssertEqual(persisted.recent.recent.first { $0.path == home }?.count, 2)
    }

    func testSaveReappliesChangeOnTopOfUnseenExternalEdit() throws {
        let store = makeStore()
        let command = store.document.commands[2] // git status
        // Hand edit (not yet delivered by a watcher): rename and add a location.
        var external = store.document
        external.commands[2].name = "Status (edited)"
        external.locations.append(WorkspaceLocation(name: "Added", path: "/added"))
        try external.encoded().write(to: fileURL)

        store.edit { doc in
            guard let idx = doc.commands.firstIndex(where: { $0.id == command.id }) else { return }
            doc.commands[idx].pinned = true
        }

        let onDisk = try WorkspaceDocument.decode(Data(contentsOf: fileURL))
        XCTAssertTrue(onDisk.locations.contains { $0.name == "Added" })
        let saved = try XCTUnwrap(onDisk.commands.first { $0.id == command.id })
        XCTAssertEqual(saved.name, "Status (edited)")
        XCTAssertTrue(saved.pinned)
        XCTAssertEqual(store.document, onDisk)
    }

    func testRecordUseOfLocationDoesNotDoubleCountTheFollowingShellReport() {
        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore(now: { clock })
        let home = store.document.locations[0] // ~
        store.recordUse(location: home)
        store.commitVisit(home.expandedPath) // the shell's OSC 7 after the cd
        XCTAssertEqual(store.recent.recent.first { $0.path == home.expandedPath }?.count, 1)
    }

    func testRecordVisitChecksExistenceOffMainAndCommits() async throws {
        let store = makeStore(visitDebounce: 0)
        let home = NSHomeDirectory()
        let expectation = expectation(description: "visit committed")
        let cancellable = store.$recent
            .filter { $0.recent.contains { $0.path == home } }
            .first()
            .sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }
        store.recordVisit(URL(fileURLWithPath: "/definitely/not/a/real/dir"))
        // Let the first report finish its stat; it must not be recorded.
        try await Task.sleep(nanoseconds: 200_000_000)
        store.recordVisit(URL(fileURLWithPath: home))
        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertFalse(store.recent.recent.contains { $0.path == "/definitely/not/a/real/dir" })
    }

    func testRecordVisitIgnoresNonKeyWindows() async throws {
        let store = makeStore(visitDebounce: 0)
        store.recordVisit(URL(fileURLWithPath: NSHomeDirectory()), window: nil)
        store.recordVisit(URL(fileURLWithPath: NSHomeDirectory()), window: NSWindow())
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(store.recent.recent.isEmpty)
    }

    func testRecordVisitIgnoresNonFileAndScratchURLs() {
        let store = makeStore(visitDebounce: 0)
        store.recordVisit(nil)
        store.recordVisit(URL(string: "https://example.com/x"))
        store.recordVisit(URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(store.recent.recent.isEmpty)
    }

    func testReloadPicksUpExternalEdits() throws {
        let store = makeStore()
        let json = """
        {"locations":[{"name":"Synced","path":"~/Synced","pinned":true}],
         "commands":[{"name":"Hello","command":"echo hello","confirm":false}]}
        """
        try Data(json.utf8).write(to: fileURL)
        store.reload()
        XCTAssertEqual(store.document.locations.map(\.name), ["Synced"])
        XCTAssertEqual(store.document.commands.first?.confirm, false)
    }

    func testWatcherReloadsWhenFileReplacedOnDisk() async throws {
        let store = makeStore(watch: true)
        XCTAssertEqual(store.document.locations.count, 3)

        // Simulate a sync tool: write a temp file and rename it over ours.
        let temp = fileURL.deletingLastPathComponent().appendingPathComponent("incoming.tmp")
        try Data(#"{"locations":[{"name":"FromSync","path":"~/Sync"}]}"#.utf8).write(to: temp)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)

        let expectation = expectation(description: "reloaded")
        let cancellable = store.$document
            .filter { $0.locations.map(\.name) == ["FromSync"] }
            .first()
            .sink { _ in expectation.fulfill() }
        defer { cancellable.cancel() }
        await fulfillment(of: [expectation], timeout: 5)
    }

    func testAtomicWriteFollowsSymlink() throws {
        let realDir = directory.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let real = realDir.appendingPathComponent("workspace.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: real)

        try WorkspaceStore.writeAtomically(Data("{\"version\":1}\n".utf8), to: fileURL)

        // The symlink is still a symlink and the target got the content.
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "{\"version\":1}\n")
    }
}

// MARK: - Sharing workspace.json between machines

final class WorkspaceSyncModelTests: XCTestCase {
    /// A file written by a newer Slimer / another platform, already in the
    /// canonical form (every known key present, sorted, pretty printed).
    private let newerFile = #"""
    {
      "commands" : [
        {
          "command" : "git status",
          "confirm" : true,
          "cwds" : {
            "windows" : "C:\\Users\\zach\\dev"
          },
          "id" : "0F0E4A2E-0B3F-4D3F-8C6B-2A4C9B1D7E22",
          "name" : "Status",
          "pinned" : false,
          "shell" : "pwsh"
        },
        {
          "name" : "no command"
        }
      ],
      "futureTopLevel" : {
        "list" : [
          1,
          2.5,
          null,
          true,
          "x"
        ]
      },
      "locations" : [
        42,
        {
          "id" : "6C0B5D54-7E2B-4B5B-9F6B-6A7B6B9C4E11",
          "name" : "Backend",
          "path" : "~/Dev/league-view-backend",
          "paths" : {
            "freebsd" : 7,
            "windows" : "\\\\wsl$\\Ubuntu\\home\\zach\\dev\\league-view-backend"
          },
          "pinned" : "yes",
          "startupConfirm" : true,
          "tags" : [
            "work"
          ],
          "useCount" : 12
        },
        {
          "name" : "Broken",
          "path" : ""
        },
        {
          "id" : "7C0B5D54-7E2B-4B5B-9F6B-6A7B6B9C4E11",
          "name" : "Windows only",
          "paths" : {
            "windows" : "C:\\Users\\zach"
          },
          "pinned" : false,
          "startupConfirm" : true
        }
      ],
      "recent" : [
        {
          "count" : 3,
          "lastVisited" : "2026-10-27T09:12:00Z",
          "path" : "C:\\Users\\zach\\dev"
        }
      ],
      "version" : 1
    }

    """#

    func testRoundTripIsLossless() throws {
        let data = Data(newerFile.utf8)
        let doc = try WorkspaceDocument.decode(data)

        XCTAssertEqual(doc.locations.map(\.name), ["Backend", "Windows only"])
        XCTAssertEqual(doc.unusableLocations.map(\.index), [0, 2])
        XCTAssertEqual(doc.commands.map(\.name), ["Status"])
        XCTAssertEqual(doc.unusableCommands.map(\.index), [1])
        XCTAssertFalse(doc.locations[0].pinned) // "yes" is not a Bool

        // Byte for byte: unknown document keys, unknown entry keys, a known
        // key with a value of the wrong type, and unusable entries in place.
        XCTAssertEqual(String(bytes: try doc.encoded(), encoding: .utf8), newerFile)
    }

    func testEditsKeepUnknownDataAndPositions() throws {
        var doc = try WorkspaceDocument.decode(Data(newerFile.utf8))
        doc.locations[0].name = "Renamed"
        doc.locations.append(WorkspaceLocation(name: "New", path: "~/new"))
        let json = try JSONValue.decode(doc.encoded())

        let top = try XCTUnwrap(json.objectValue)
        XCTAssertEqual(top["futureTopLevel"], try JSONValue.decode(Data(newerFile.utf8)).objectValue?["futureTopLevel"])
        XCTAssertNotNil(top["recent"])
        let locations = try XCTUnwrap(top["locations"]?.arrayValue)
        XCTAssertEqual(locations.count, 5)
        XCTAssertEqual(locations[0], .int(42))
        XCTAssertEqual(locations[2].objectValue?["name"], .string("Broken"))
        let backend = try XCTUnwrap(locations[1].objectValue)
        XCTAssertEqual(backend["name"], .string("Renamed"))
        XCTAssertEqual(backend["tags"], .array([.string("work")]))
        XCTAssertEqual(backend["pinned"], .string("yes"))
        XCTAssertEqual(backend["useCount"], .int(12))
        XCTAssertEqual(backend["paths"]?.objectValue?["freebsd"], .int(7))
        XCTAssertEqual(locations[4].objectValue?["name"], .string("New"))

        // Changing a field with an unusable value replaces it.
        doc.locations[0].pinned = true
        let pinned = try JSONValue.decode(doc.encoded()).objectValue?["locations"]?.arrayValue?[1].objectValue?["pinned"]
        XCTAssertEqual(pinned, .bool(true))
    }

    func testEntriesWithoutIDGetStableDistinctIDs() throws {
        let json = #"{"locations":[{"path":"~/a"},{"path":"~/a"},{"path":"~/b"}]}"#
        let first = try WorkspaceDocument.decode(Data(json.utf8))
        let second = try WorkspaceDocument.decode(Data(json.utf8))
        XCTAssertEqual(first.locations.map(\.id), second.locations.map(\.id))
        XCTAssertEqual(Set(first.locations.map(\.id)).count, 3)
    }

    func testPerOSPathResolution() throws {
        let json = #"""
        {"locations":[
          {"name":"portable","path":"~/Dev/app"},
          {"name":"override","path":"~/Dev/app","paths":{"macos":"/Volumes/Work/app","windows":"C:\\dev\\app"}},
          {"name":"windows-only","paths":{"windows":"C:\\dev\\app"}},
          {"name":"windows-path","path":"C:\\dev\\app"},
          {"name":"wsl","path":"\\\\wsl$\\Ubuntu\\home\\zach"},
          {"name":"blank-mac","path":"/opt","paths":{"macos":"  "}}
         ],
         "commands":[
          {"name":"anywhere","command":"ls"},
          {"name":"mac","command":"ls","cwds":{"macos":"~/Dev"}},
          {"name":"win-only","command":"dir","cwds":{"windows":"C:\\dev"}},
          {"name":"win-cwd","command":"dir","cwd":"C:\\dev"},
          {"name":"override","command":"ls","cwd":"C:\\dev","cwds":{"macos":"/opt"}}
         ]}
        """#
        let doc = try WorkspaceDocument.decode(Data(json.utf8))
        XCTAssertEqual(doc.locations.count, 6) // all kept
        XCTAssertEqual(doc.visibleLocations.map(\.name), ["portable", "override", "blank-mac"])
        XCTAssertEqual(doc.locations[1].expandedPath, "/Volumes/Work/app")
        XCTAssertEqual(doc.locations[5].expandedPath, "/opt")
        XCTAssertEqual(doc.locations[2].name, "windows-only")
        XCTAssertEqual(Set(doc.rankedLocations().map(\.name)), ["portable", "override", "blank-mac"])

        XCTAssertEqual(doc.visibleCommands.map(\.name), ["anywhere", "mac", "override"])
        XCTAssertNil(doc.commands[0].currentCwd)
        XCTAssertEqual(doc.commands[1].currentCwd, "~/Dev")
        XCTAssertEqual(doc.commands[4].currentCwd, "/opt")
        XCTAssertEqual(Set(doc.rankedCommands().map(\.name)), ["anywhere", "mac", "override"])
    }

    func testMovingVisibleEntriesKeepsHiddenSlots() throws {
        let json = #"{"locations":[{"name":"a","path":"/a"},{"name":"win","path":"C:\\x"},{"name":"b","path":"/b"},{"name":"c","path":"/c"}]}"#
        var doc = try WorkspaceDocument.decode(Data(json.utf8))
        // Settings shows a, b, c; drag c to the top.
        doc.moveVisibleLocations(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(doc.locations.map(\.name), ["c", "win", "a", "b"])
    }

    func testSettingsEditChangesOnlyThisOSPath() throws {
        let json = #"{"locations":[{"id":"6C0B5D54-7E2B-4B5B-9F6B-6A7B6B9C4E11","name":"app","path":"~/Dev/app","paths":{"macos":"~/Mac/app","windows":"C:\\dev\\app"},"extra":1}]}"#
        var doc = try WorkspaceDocument.decode(Data(json.utf8))
        var draft = doc.locations[0]
        XCTAssertEqual(draft.editablePath, "~/Mac/app")
        draft.editablePath = "~/Mac/renamed"
        draft.name = "renamed"
        doc.locations[0].applyEdits(from: draft)

        let saved = try XCTUnwrap(JSONValue.decode(doc.encoded()).objectValue?["locations"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(saved["path"], .string("~/Dev/app"))
        XCTAssertEqual(saved["paths"], .object(["macos": .string("~/Mac/renamed"), "windows": .string("C:\\dev\\app")]))
        XCTAssertEqual(saved["extra"], .int(1))
        XCTAssertEqual(saved["name"], .string("renamed"))

        // Without a macOS override the portable path is edited.
        var plain = WorkspaceLocation(name: "p", path: "~/p")
        plain.editablePath = "~/q"
        XCTAssertEqual(plain.path, "~/q")
        XCTAssertNil(plain.paths)
    }

    func testLocalDirectory() {
        let home = "/Users/tester"
        XCTAssertEqual(
            WorkspacePath.localDirectory(environment: [:], home: home).path,
            "/Users/tester/Library/Application Support/Slimer"
        )
        XCTAssertEqual(WorkspacePath.localDirectory(environment: ["XDG_STATE_HOME": "/state"], home: home).path, "/state/slimer")
        XCTAssertEqual(
            WorkspacePath.localDirectory(environment: ["XDG_STATE_HOME": "relative"], home: home).path,
            "/Users/tester/Library/Application Support/Slimer"
        )
        let test = WorkspacePath.localDirectory(environment: ["XCTestConfigurationFilePath": "/x"], home: home)
        XCTAssertTrue(test.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).path), test.path)
        XCTAssertFalse(WorkspaceStore.shared.recentFileURL.path.contains("Application Support"))
    }
}

extension WorkspaceStoreTests {
    func testNewerVersionIsReadOnly() throws {
        let json = #"{"version":2,"locations":[{"name":"Dev","path":"~/Dev","newThing":{"a":1}}],"commands":[{"command":"ls"}]}"#
        try writeFile(json)
        let original = try Data(contentsOf: fileURL)

        let store = makeStore()
        XCTAssertNil(store.loadError)
        XCTAssertFalse(store.acceptsEdits)
        XCTAssertEqual(store.rankedLocations().map(\.name), ["Dev"]) // still shown

        store.recordUse(location: store.document.locations[0])
        store.recordUse(command: store.document.commands[0])
        store.edit { $0.locations.removeAll() }
        store.commitVisit(NSHomeDirectory())

        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(store.document.locations.count, 1)
    }

    func testRecentMigratesOnlyThisMachinesPathsAndLeavesFileUntouched() throws {
        let json = #"""
        {"locations":[],"recent":[
          {"path":"/Users/me/Dev","count":4,"lastVisited":"2026-10-27T09:12:00Z"},
          {"path":"C:\\Users\\zach\\dev","count":9,"lastVisited":"2026-10-27T09:12:00Z"},
          {"path":"\\\\wsl$\\Ubuntu\\home","count":2,"lastVisited":"2026-10-27T09:12:00Z"},
          {"path":"/Users/me/Other","count":1,"lastVisited":"2026-10-20T09:12:00Z"}
        ]}
        """#
        try writeFile(json)
        let original = try Data(contentsOf: fileURL)

        let store = makeStore()
        XCTAssertEqual(Set(store.recent.recent.map(\.path)), ["/Users/me/Dev", "/Users/me/Other"])
        XCTAssertEqual(store.recent.recent.first { $0.path == "/Users/me/Dev" }?.count, 4)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)

        // recent.json was written (0600) and the migration is not repeated.
        let recentFile = localDirectory.appendingPathComponent("recent.json")
        XCTAssertEqual(try permissions(of: recentFile) & 0o777, 0o600)
        store.clearRecent()
        let again = makeStore()
        XCTAssertTrue(again.recent.recent.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testUsageIsStoredLocallyAndWorkspaceFileUnchanged() throws {
        let json = #"{"locations":[{"id":"6C0B5D54-7E2B-4B5B-9F6B-6A7B6B9C4E11","name":"Home","path":"~","useCount":3,"lastUsed":"2026-01-01T00:00:00Z"}],"commands":[{"id":"0F0E4A2E-0B3F-4D3F-8C6B-2A4C9B1D7E22","command":"ls"}]}"#
        try writeFile(json)
        let original = try Data(contentsOf: fileURL)
        let clock = Date(timeIntervalSince1970: 1_800_000_000)

        let store = makeStore(now: { clock })
        store.recordUse(location: store.document.locations[0])
        store.recordUse(command: store.document.commands[0])

        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        let usageFile = localDirectory.appendingPathComponent("usage.json")
        XCTAssertEqual(try permissions(of: usageFile) & 0o777, 0o600)
        let usage = WorkspaceUsageDocument(json: try JSONValue.decode(Data(contentsOf: usageFile)))
        let locationID = try XCTUnwrap(UUID(uuidString: "6C0B5D54-7E2B-4B5B-9F6B-6A7B6B9C4E11"))
        let commandID = try XCTUnwrap(UUID(uuidString: "0F0E4A2E-0B3F-4D3F-8C6B-2A4C9B1D7E22"))
        XCTAssertEqual(usage.entries[locationID], WorkspaceUsage(count: 4, lastUsed: clock)) // seeded from the file's 3
        XCTAssertEqual(usage.entries[commandID], WorkspaceUsage(count: 1, lastUsed: clock))
    }

    func testSettingsEditOfMacPathWritesOnlyThatValue() throws {
        let json = #"{"locations":[{"id":"6C0B5D54-7E2B-4B5B-9F6B-6A7B6B9C4E11","name":"app","path":"~/Dev/app","paths":{"macos":"~/Mac/app","windows":"C:\\dev\\app"},"useCount":2}]}"#
        try writeFile(json)
        let store = makeStore()
        var draft = store.document.locations[0]
        draft.editablePath = "~/Mac/moved"
        // What LocationsEditor does on "Save Location".
        store.edit { doc in
            guard let idx = doc.locations.firstIndex(where: { $0.id == draft.id }) else { return }
            doc.locations[idx].applyEdits(from: draft)
        }

        let saved = try XCTUnwrap(JSONValue.decode(Data(contentsOf: fileURL)).objectValue?["locations"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(saved["path"], .string("~/Dev/app"))
        XCTAssertEqual(saved["paths"], .object(["macos": .string("~/Mac/moved"), "windows": .string("C:\\dev\\app")]))
        XCTAssertEqual(saved["useCount"], .int(2))
        XCTAssertEqual(store.document.locations[0].expandedPath, WorkspacePath.expand("~/Mac/moved"))
    }
}
