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
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let original = WorkspaceDocument(
            locations: [
                WorkspaceLocation(
                    name: "Backend",
                    path: "~/Dev/league-view-backend",
                    icon: "server.rack",
                    color: "#FF8800",
                    pinned: true,
                    shortcut: "cmd+shift+1",
                    startupCommand: "claude",
                    useCount: 3,
                    lastUsed: date
                ),
            ],
            commands: [
                WorkspaceCommand(
                    name: "Status",
                    command: "git status",
                    cwd: "~/Dev",
                    pinned: false,
                    shortcut: "cmd+shift+g",
                    confirm: false,
                    useCount: 1,
                    lastUsed: date
                ),
            ],
            recent: [
                WorkspaceRecentDirectory(path: "/Users/me/Dev", count: 4, lastVisited: date),
            ]
        )

        let data = try original.encoded()
        let decoded = try WorkspaceDocument.decode(data)
        XCTAssertEqual(decoded, original)

        // Human-friendly on disk: pretty printed, ISO 8601 dates, unescaped slashes.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"lastUsed\" : \"2023-11-14T22:13:20Z\""), text)
        XCTAssertTrue(text.contains("~/Dev/league-view-backend"), text)
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
        XCTAssertEqual(doc.locations[1].useCount, 0)
        XCTAssertNil(doc.locations[1].lastUsed)

        XCTAssertEqual(doc.commands.count, 1)
        XCTAssertEqual(doc.commands[0].name, "claude")
        XCTAssertTrue(doc.commands[0].confirm) // default is true

        XCTAssertEqual(doc.recent.count, 1)
        XCTAssertEqual(doc.recent[0].lastVisited, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testTolerantParsingOfMissingSections() throws {
        let doc = try WorkspaceDocument.decode(Data("{}".utf8))
        XCTAssertEqual(doc.version, WorkspaceDocument.currentVersion)
        XCTAssertTrue(doc.locations.isEmpty)
        XCTAssertTrue(doc.commands.isEmpty)
        XCTAssertTrue(doc.recent.isEmpty)
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
        var doc = WorkspaceDocument()
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
        var doc = WorkspaceDocument()
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

    func testLocationsPinnedFirstThenFrecencyThenName() {
        var doc = WorkspaceDocument(locations: [
            WorkspaceLocation(name: "zeta", path: "/z"),
            WorkspaceLocation(name: "alpha", path: "/a"),
            WorkspaceLocation(name: "pinned", path: "/p", pinned: true),
            WorkspaceLocation(name: "used", path: "/u"),
        ])
        let usedID = doc.locations[3].id
        XCTAssertTrue(doc.recordUse(locationID: usedID, now: now.addingTimeInterval(-10)))
        XCTAssertFalse(doc.recordUse(locationID: UUID(), now: now))

        XCTAssertEqual(doc.rankedLocations(now: now).map(\.name), ["pinned", "used", "alpha", "zeta"])
    }

    func testCommandsPinnedFirstThenFrecency() {
        var doc = WorkspaceDocument(commands: [
            WorkspaceCommand(name: "b", command: "b"),
            WorkspaceCommand(name: "a", command: "a"),
            WorkspaceCommand(name: "p", command: "p", pinned: true),
        ])
        doc.recordUse(commandID: doc.commands[0].id, now: now)
        XCTAssertEqual(doc.rankedCommands(now: now).map(\.name), ["p", "b", "a"])
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

// MARK: - Store (disk)

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private var directory: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-workspace-tests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directory.appendingPathComponent("sub/workspace.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func permissions(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? Int)
    }

    func testFirstRunSeedsFileWithRestrictedPermissions() throws {
        let store = WorkspaceStore(fileURL: fileURL, watch: false)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.document.locations.map(\.path), ["~", "~/Dev", "~/Dev/league-view-backend"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try permissions(of: fileURL) & 0o777, 0o600)
        XCTAssertEqual(try permissions(of: fileURL.deletingLastPathComponent()) & 0o777, 0o700)

        // No leftover temp files from the atomic write.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers, ["workspace.json"])

        // A second store reads the same document back.
        let again = WorkspaceStore(fileURL: fileURL, watch: false)
        XCTAssertEqual(again.document, store.document)
    }

    func testInvalidFileIsKeptInMemoryAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: fileURL)

        let store = WorkspaceStore(fileURL: fileURL, watch: false)
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
        let store = WorkspaceStore(fileURL: fileURL, watch: false, now: { clock })
        let location = store.document.locations[1] // ~/Dev
        store.recordUse(location: location)
        clock = clock.addingTimeInterval(120)
        store.recordUse(location: location)

        let reloaded = WorkspaceStore(fileURL: fileURL, watch: false)
        let saved = try XCTUnwrap(reloaded.document.locations.first { $0.id == location.id })
        XCTAssertEqual(saved.useCount, 2)
        XCTAssertEqual(saved.lastUsed, clock)
        // Using a location also counts as visiting its directory.
        XCTAssertTrue(reloaded.document.recent.contains { $0.path == location.expandedPath })

        // Visits: nonexistent paths are ignored, existing ones are counted once per minute.
        store.commitVisit("/definitely/not/a/real/dir")
        XCTAssertFalse(store.document.recent.contains { $0.path == "/definitely/not/a/real/dir" })

        let home = NSHomeDirectory()
        store.commitVisit(home)
        store.commitVisit(home)
        XCTAssertEqual(store.document.recent.first { $0.path == home }?.count, 1)
        clock = clock.addingTimeInterval(61)
        store.commitVisit(home)
        XCTAssertEqual(store.document.recent.first { $0.path == home }?.count, 2)

        let persisted = WorkspaceStore(fileURL: fileURL, watch: false)
        XCTAssertEqual(persisted.document.recent.first { $0.path == home }?.count, 2)
    }

    func testRecordVisitIgnoresNonFileAndScratchURLs() {
        let store = WorkspaceStore(fileURL: fileURL, watch: false, visitDebounce: 0)
        store.recordVisit(nil)
        store.recordVisit(URL(string: "https://example.com/x"))
        store.recordVisit(URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(store.document.recent.isEmpty)
    }

    func testReloadPicksUpExternalEdits() throws {
        let store = WorkspaceStore(fileURL: fileURL, watch: false)
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
        let store = WorkspaceStore(fileURL: fileURL, watch: true)
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
