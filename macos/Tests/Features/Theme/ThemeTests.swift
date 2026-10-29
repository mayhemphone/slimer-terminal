import AppKit
import Foundation
import Testing
@testable import Ghostty

// MARK: - Hex validation

@Suite
struct SurfaceThemeHexTests {
    @Test(arguments: ["#000000", "#FFFFFF", "#aBcDeF", "#112233"])
    func acceptsStrictRRGGBB(_ value: String) {
        #expect(SurfaceTheme.isValidHex(value))
    }

    @Test(arguments: [
        "", "#", "#FFF", "#FFFFFFFF", "FFFFFF", "#GGGGGG", " #FFFFFF", "#FFFFFF ",
        "#FFFFF", "#FFFFFFF", "red", "#ff ff ff", "#FFFFFF\n", "#ＦＦＦＦＦＦ",
    ])
    func rejectsEverythingElse(_ value: String) {
        #expect(!SurfaceTheme.isValidHex(value))
    }

    @Test func sanitizedDropsInvalidColorsAndControlCharsInThemeName() {
        let theme = SurfaceTheme(
            name: "  Odd  ",
            ghosttyTheme: "Nord\nfont-size=99",
            background: "#112233",
            foreground: "not-a-color",
            cursorColor: "#FFF",
            selectionBackground: "#AABBCC",
            accent: "#12345G"
        ).sanitized()
        #expect(theme.name == "Odd")
        #expect(theme.ghosttyTheme == nil)
        #expect(theme.background == "#112233")
        #expect(theme.foreground == nil)
        #expect(theme.cursorColor == nil)
        #expect(theme.selectionBackground == "#AABBCC")
        #expect(theme.accent == nil)
    }

    @Test func strictHexColorRoundTripsInSRGB() {
        for hex in ["#3DDC84", "#000000", "#FFFFFF", "#0B1A12", "#F26B3A"] {
            #expect(NSColor(strictHex: hex)?.strictHexString == hex)
        }
        #expect(NSColor(strictHex: "3DDC84") == nil)
        #expect(NSColor(strictHex: "#3DDC8400") == nil)
    }

    @Test func strictHexStringClampsOutOfGamutColors() throws {
        // Extended-range sRGB components outside 0...1 must clamp, not wrap or overflow.
        let wide = NSColor(srgbRed: 1.4, green: -0.3, blue: 0.5, alpha: 1)
        let hex = try #require(wide.strictHexString)
        #expect(SurfaceTheme.isValidHex(hex))
        #expect(hex.hasPrefix("#FF00"))
    }
}

// MARK: - Applier args

@Suite
struct ThemeApplierArgsTests {
    @Test func emitsNamedThemeColorsFirstThenExplicitColors() {
        let theme = SurfaceTheme(
            name: "Full",
            ghosttyTheme: "Catppuccin Mocha",
            background: "#010203",
            foreground: "#040506",
            cursorColor: "#070809",
            selectionBackground: "#0A0B0C",
            accent: "#0D0E0F"
        )
        let named = ["background=#111111", "palette=1=#AA0000"]
        #expect(ThemeApplier.configArgs(for: theme, namedThemeArgs: named) == [
            "background=#111111",
            "palette=1=#AA0000",
            "background=#010203",
            "foreground=#040506",
            "cursor-color=#070809",
            "selection-background=#0A0B0C",
        ])
    }

    @Test func skipsUnsetAndInvalidFieldsAndNeverEmitsAccent() {
        let theme = SurfaceTheme(name: "Partial", background: "#112233", foreground: "nope", accent: "#FFFFFF")
        #expect(ThemeApplier.configArgs(for: theme) == ["background=#112233"])
        #expect(theme.affectsTerminalConfig)

        let accentOnly = SurfaceTheme(name: "Accent", accent: "#FFFFFF")
        #expect(ThemeApplier.configArgs(for: accentOnly).isEmpty)
        #expect(!accentOnly.affectsTerminalConfig)
    }

    @Test func neverEmitsThemeNamesOrPaths() {
        for name in ["Nord", "/tmp/evil", "light:/a,dark:/b", "Nord\nkeybind=enter=text:x"] {
            let theme = SurfaceTheme(name: "T", ghosttyTheme: name)
            let args = ThemeApplier.configArgs(for: theme)
            #expect(args.isEmpty)
            #expect(!args.contains { $0.hasPrefix("theme=") })
        }
    }
}

// MARK: - Rules

@Suite
struct ThemeRuleMatcherTests {
    let home = "/Users/zach"
    let green = UUID()
    let blue = UUID()
    let red = UUID()

    @Test func standardizesTildeDotsAndSlashes() {
        #expect(ThemeRuleMatcher.standardizePath("~", home: home) == "/Users/zach")
        #expect(ThemeRuleMatcher.standardizePath("~/Dev//x/./y/", home: home) == "/Users/zach/Dev/x/y")
        #expect(ThemeRuleMatcher.standardizePath("/a/b/../c", home: home) == "/a/c")
        #expect(ThemeRuleMatcher.standardizePath("/../..", home: home) == "/")
        #expect(ThemeRuleMatcher.standardizePath("relative/dir", home: home) == "relative/dir")
    }

    @Test func pathPrefixIsComponentWise() {
        #expect(ThemeRuleMatcher.pathHasPrefix("/a/b/c", prefix: "/a/b"))
        #expect(ThemeRuleMatcher.pathHasPrefix("/a/b", prefix: "/a/b"))
        #expect(ThemeRuleMatcher.pathHasPrefix("/a/b", prefix: "/"))
        #expect(!ThemeRuleMatcher.pathHasPrefix("/a/bc", prefix: "/a/b"))
        #expect(!ThemeRuleMatcher.pathHasPrefix("relative", prefix: "/"))
    }

    @Test func tildeRuleMatchesExpandedPwdAndViceVersa() {
        let rules = [ThemeRule(match: .pathPrefix("~/Dev/league-view-backend"), themeId: green)]
        let ctx = ThemeRuleMatcher.Context(pwd: "/Users/zach/Dev/league-view-backend/src")
        #expect(ThemeRuleMatcher.match(rules: rules, context: ctx, home: home)?.themeId == green)

        let other = ThemeRuleMatcher.Context(pwd: "/Users/zach/Dev/league-view-backend-v2")
        #expect(ThemeRuleMatcher.match(rules: rules, context: other, home: home) == nil)

        let noPwd = ThemeRuleMatcher.Context(pwd: nil)
        #expect(ThemeRuleMatcher.match(rules: rules, context: noPwd, home: home) == nil)
    }

    @Test func priorityBeatsSpecificityAndSpecificityBeatsOrder() {
        let ctx = ThemeRuleMatcher.Context(pwd: "/Users/zach/Dev/app/api")

        // Same priority: the deeper prefix wins regardless of order.
        let bySpecificity = [
            ThemeRule(match: .pathPrefix("~/Dev"), themeId: blue),
            ThemeRule(match: .pathPrefix("~/Dev/app"), themeId: green),
        ]
        #expect(ThemeRuleMatcher.match(rules: bySpecificity, context: ctx, home: home)?.themeId == green)
        #expect(ThemeRuleMatcher.match(rules: bySpecificity.reversed(), context: ctx, home: home)?.themeId == green)

        // Higher priority wins even when less specific.
        let byPriority = [
            ThemeRule(match: .pathPrefix("~/Dev/app"), themeId: green, priority: 0),
            ThemeRule(match: .pathPrefix("~/Dev"), themeId: red, priority: 10),
        ]
        #expect(ThemeRuleMatcher.match(rules: byPriority, context: ctx, home: home)?.themeId == red)

        // Full tie: first in file order wins.
        let tie = [
            ThemeRule(match: .pathPrefix("~/Dev/app"), themeId: blue),
            ThemeRule(match: .pathPrefix("~/Dev/app"), themeId: green),
        ]
        #expect(ThemeRuleMatcher.match(rules: tie, context: ctx, home: home)?.themeId == blue)
    }

    @Test func remoteHostRequiresBoundaryAndOutranksLocal() {
        #expect(ThemeRuleMatcher.titleNamesRemoteHost("me@prod: ~", host: "prod"))
        #expect(ThemeRuleMatcher.titleNamesRemoteHost("me@prod", host: "prod"))
        #expect(ThemeRuleMatcher.titleNamesRemoteHost("me@prod.example.com", host: "prod"))
        #expect(ThemeRuleMatcher.titleNamesRemoteHost("ssh me@prod top", host: "prod"))
        #expect(!ThemeRuleMatcher.titleNamesRemoteHost("me@production: ~", host: "prod"))
        #expect(!ThemeRuleMatcher.titleNamesRemoteHost("me@prod-db: ~", host: "prod"))
        #expect(ThemeRuleMatcher.titleNamesRemoteHost("x@prodx y@prod:", host: "prod"))

        // On "laptop", ssh'd into "prod": the remote rule wins even though it comes later.
        let rules = [
            ThemeRule(match: .hostname("laptop-long-name"), themeId: blue),
            ThemeRule(match: .hostname("prod"), themeId: red),
        ]
        let ctx = ThemeRuleMatcher.Context(title: "me@prod: ~", localHostnames: ["laptop-long-name"])
        #expect(ThemeRuleMatcher.match(rules: rules, context: ctx, home: home)?.themeId == red)
    }

    @Test func specificityIsNotComparedAcrossKinds() {
        // A long command value must not beat an earlier, equally prioritized path rule.
        let rules = [
            ThemeRule(match: .pathPrefix("~/Dev"), themeId: green),
            ThemeRule(match: .command("a-very-long-command-name"), themeId: red),
        ]
        let ctx = ThemeRuleMatcher.Context(pwd: "/Users/zach/Dev/x", title: "a-very-long-command-name")
        #expect(ThemeRuleMatcher.match(rules: rules, context: ctx, home: home)?.themeId == green)
        #expect(ThemeRuleMatcher.match(rules: rules.reversed(), context: ctx, home: home)?.themeId == red)

        // Priority still crosses kinds.
        let prioritized = [
            ThemeRule(match: .pathPrefix("~/Dev"), themeId: green),
            ThemeRule(match: .command("a-very-long-command-name"), themeId: red, priority: 1),
        ]
        #expect(ThemeRuleMatcher.match(rules: prioritized, context: ctx, home: home)?.themeId == red)
    }

    @Test func hostnameMatchesLocalNamesOrSshStyleTitles() {
        let rules = [ThemeRule(match: .hostname("prod-db"), themeId: red)]
        let local = ThemeRuleMatcher.Context(localHostnames: ["prod-db", "prod-db.internal"])
        #expect(ThemeRuleMatcher.match(rules: rules, context: local, home: home)?.themeId == red)

        let ssh = ThemeRuleMatcher.Context(title: "zach@PROD-DB: ~", localHostnames: ["laptop"])
        #expect(ThemeRuleMatcher.match(rules: rules, context: ssh, home: home)?.themeId == red)

        let miss = ThemeRuleMatcher.Context(title: "zach@staging: ~", localHostnames: ["laptop"])
        #expect(ThemeRuleMatcher.match(rules: rules, context: miss, home: home) == nil)

        #expect(ThemeRuleMatcher.localHostnames(from: "Zachs-Mac.local") == ["zachs-mac", "zachs-mac.local"])
    }

    @Test func commandMatchesTitleTokens() {
        #expect(ThemeRuleMatcher.titleNamesCommand("vim", command: "vim"))
        #expect(ThemeRuleMatcher.titleNamesCommand("vim main.swift", command: "vim"))
        #expect(ThemeRuleMatcher.titleNamesCommand("/usr/bin/vim x", command: "vim"))
        #expect(!ThemeRuleMatcher.titleNamesCommand("neovim", command: "vim"))
        #expect(!ThemeRuleMatcher.titleNamesCommand("ls vim", command: "vim"))
        #expect(!ThemeRuleMatcher.titleNamesCommand("vim", command: ""))

        let rules = [ThemeRule(match: .command("ssh"), themeId: red)]
        let ctx = ThemeRuleMatcher.Context(title: "ssh prod")
        #expect(ThemeRuleMatcher.match(rules: rules, context: ctx, home: home)?.themeId == red)
    }
}

// MARK: - themes.json

@Suite
struct ThemeStoreFileTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-theme-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("themes.json")
    }

    @Test func documentRoundTrips() throws {
        let green = SurfaceTheme(name: "Green", ghosttyTheme: "Nord", background: "#0B1A12",
                                 foreground: "#D7F5DC", cursorColor: "#5CF28A",
                                 selectionBackground: "#1E4D32", accent: "#3DDC84")
        let rule = ThemeRule(match: .pathPrefix("~/Dev"), themeId: green.id, priority: 5)
        let doc = ThemeDocument(themes: [green], rules: [rule])

        let data = try ThemeStore.encode(doc)
        let decoded = try #require(ThemeStore.decode(data))
        #expect(decoded == doc)
        #expect(decoded.droppedEntries == 0)
        #expect(ThemeStore.persistence(for: decoded) == .writable)

        // The match enum is written in the documented {kind, value} shape.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"kind\" : \"pathPrefix\""))
        #expect(json.contains("\"value\" : \"~/Dev\""))
    }

    @Test func tolerantParsingSkipsBadEntriesAndUnknownKeys() throws {
        let good = UUID()
        let json = """
        {
          "version": 1,
          "future-key": true,
          "themes": [
            {"id": "\(good.uuidString)", "name": "Good", "background": "#112233", "extra": 1},
            {"id": "not-a-uuid", "name": "Bad id"},
            {"name": "Missing id"},
            {"id": "\(good.uuidString)", "name": "Duplicate id"},
            {"id": "\(UUID().uuidString)", "name": "Bad colors", "background": "#FFF", "accent": "#ABCDEF"}
          ],
          "rules": [
            {"id": "\(UUID().uuidString)", "match": {"kind": "pathPrefix", "value": "~/x"}, "themeId": "\(good.uuidString)", "priority": 1},
            {"id": "\(UUID().uuidString)", "match": {"kind": "teleport", "value": "?"}, "themeId": "\(good.uuidString)", "priority": 1},
            {"id": "\(UUID().uuidString)", "match": {"kind": "hostname", "value": "h"}, "themeId": "\(UUID().uuidString)", "priority": 1},
            "garbage"
          ]
        }
        """
        let doc = try #require(ThemeStore.decode(Data(json.utf8)))
        #expect(doc.droppedEntries > 0)
        #expect(ThemeStore.persistence(for: doc) == .lossy)
        #expect(doc.themes.map(\.name) == ["Good", "Bad colors"])
        #expect(doc.themes[0].background == "#112233")
        #expect(doc.themes[1].background == nil)
        #expect(doc.themes[1].accent == "#ABCDEF")
        #expect(doc.rules.count == 1)
        #expect(doc.rules[0].match == .pathPrefix("~/x"))

        #expect(ThemeStore.decode(Data("not json".utf8)) == nil)
        #expect(ThemeStore.decode(Data("{}".utf8)) == ThemeDocument(themes: [], rules: []))
    }

    @Test func storeSeedsPresetsPersistsAndReloads() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ThemeStore(fileURL: url, watch: false)
        #expect(store.themes == ThemeStore.presets)
        #expect(store.rules.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let slimer = try #require(store.themes.first)
        store.setPathRule(path: "~/Dev/league-view-backend", themeId: slimer.id)
        store.setPathRule(path: "~/Dev/league-view-backend", themeId: slimer.id)
        #expect(store.rules.count == 1)

        let reopened = ThemeStore(fileURL: url, watch: false)
        #expect(reopened.themes == store.themes)
        #expect(reopened.rules == store.rules)

        // Removing a theme removes its rules; reload picks up external edits.
        store.remove(themeId: slimer.id)
        #expect(store.rules.isEmpty)
        reopened.reload()
        #expect(reopened.rules.isEmpty)
        #expect(reopened.themes.count == ThemeStore.presets.count - 1)
    }

    @Test func brokenFileIsNeverOverwrittenWithPresets() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = "{ \"themes\": [ oops"
        try broken.write(to: url, atomically: true, encoding: .utf8)

        let store = ThemeStore(fileURL: url, watch: false)
        #expect(store.persistence == .unparseable)
        #expect(store.themes == ThemeStore.presets)
        #expect(try String(contentsOf: url, encoding: .utf8) == broken)

        // An in-app edit moves the broken file aside before writing.
        store.upsert(SurfaceTheme(name: "New", background: "#123456"))
        #expect(store.persistence == .writable)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let backup = try #require(siblings.first { $0.hasPrefix("themes.json.broken-") })
        let backupURL = url.deletingLastPathComponent().appendingPathComponent(backup)
        #expect(try String(contentsOf: backupURL, encoding: .utf8) == broken)
        #expect(ThemeStore.load(from: url)?.themes.contains { $0.name == "New" } == true)
    }

    @Test func lossyOrNewerFilesAreNeverRewritten() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = UUID().uuidString
        let files = [
            // Unknown rule kind.
            """
            {"version": 1, "themes": [{"id": "\(id)", "name": "A"}],
             "rules": [{"id": "\(UUID().uuidString)", "match": {"kind": "gitBranch", "value": "main"}, "themeId": "\(id)", "priority": 0}]}
            """,
            // Unknown theme key.
            """
            {"version": 1, "themes": [{"id": "\(id)", "name": "A", "tabStyle": "bold"}], "rules": []}
            """,
            // Newer version.
            """
            {"version": 2, "themes": [{"id": "\(id)", "name": "A"}], "rules": []}
            """,
        ]
        for original in files {
            try original.write(to: url, atomically: true, encoding: .utf8)
            let store = ThemeStore(fileURL: url, watch: false)
            #expect(store.persistence == .lossy)
            store.upsert(SurfaceTheme(name: "Edit", background: "#123456"))
            #expect(store.themes.contains { $0.name == "Edit" })
            #expect(try String(contentsOf: url, encoding: .utf8) == original)
        }
    }

    @Test func fifoThemesFileDoesNotHang() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(mkfifo(url.path, 0o600) == 0)
        let store = ThemeStore(fileURL: url, watch: false)
        #expect(store.persistence == .unreadable)
        #expect(store.themes == ThemeStore.presets)
    }

    @Test func xdgConfigHomeIsRespected() {
        let xdg = ThemeStore.defaultFileURL(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"])
        #expect(xdg.path == "/tmp/xdg/slimer/themes.json")

        let fallback = ThemeStore.defaultFileURL(environment: ["XDG_CONFIG_HOME": "relative"])
        #expect(fallback.path.hasSuffix("/.config/slimer/themes.json"))
    }

    @Test func presetsAreValidAndStable() {
        let ids = Set(ThemeStore.presets.map(\.id))
        #expect(ids.count == ThemeStore.presets.count)
        for preset in ThemeStore.presets {
            #expect(preset.sanitized() == preset)
            #expect(preset.accent != nil)
            #expect(preset.background != nil)
            #expect(preset.foreground != nil)
        }
    }
}

// MARK: - Named Ghostty themes

@Suite
struct GhosttyThemeResolverTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-theme-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test(arguments: ["Nord", "Catppuccin Mocha", "Builtin Solarized Dark", "iTerm2 Dark Background"])
    func acceptsPlainNames(_ name: String) {
        #expect(GhosttyThemeResolver.isSafeName(name))
    }

    @Test(arguments: [
        "", "/etc/passwd", "/tmp/evil", "../evil", "a/../b", "sub/name", "a\\b", "~/evil", "~",
        ".hidden", "..", "Nord\nkeybind=x", "Nord\u{0}",
    ])
    func rejectsPathsAndControlCharacters(_ name: String) {
        #expect(!GhosttyThemeResolver.isSafeName(name))
    }

    @Test func selectsLightOrDarkFromPairs() {
        #expect(GhosttyThemeResolver.selectName("Nord", dark: true) == "Nord")
        #expect(GhosttyThemeResolver.selectName("light:A,dark:B", dark: true) == "B")
        #expect(GhosttyThemeResolver.selectName("light:A, dark:B", dark: false) == "A")
        #expect(GhosttyThemeResolver.selectName("dark:B", dark: false) == "B")
        #expect(GhosttyThemeResolver.selectName("light:A,bogus", dark: false) == nil)
    }

    @Test func parsesOnlyColorKeysFromThemeFiles() {
        let text = """
        # a hostile "theme"
        background = #1E1E2E
        foreground=cdd6f4
        cursor-color = "#F5E0DC"
        selection-background = #585b70
        palette = 0=#45475a
        palette = 15 = #A6ADC8
        palette = 16=#FFFFFF
        palette = 99=#FFFFFF
        keybind = enter=text:rm -rf ~\\n
        clipboard-read = allow
        title-report = true
        config-file = /tmp/more
        command = /bin/sh
        background = notacolor
        cursor-text = #GGGGGG
        """
        #expect(GhosttyThemeResolver.parseColorArgs(text) == [
            "background=#1E1E2E",
            "foreground=#cdd6f4",
            "cursor-color=#F5E0DC",
            "selection-background=#585b70",
            "palette=0=#45475a",
            "palette=15=#A6ADC8",
        ])
    }

    @Test func resolvesFromDirectoriesInOrderAndRejectsTraversal() throws {
        let user = try makeDir()
        let bundled = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: user)
            try? FileManager.default.removeItem(at: bundled)
        }
        try "background = #111111".write(to: user.appendingPathComponent("Mine"), atomically: true, encoding: .utf8)
        try "background = #222222".write(to: bundled.appendingPathComponent("Mine"), atomically: true, encoding: .utf8)
        try "background = #333333".write(to: bundled.appendingPathComponent("Shipped"), atomically: true, encoding: .utf8)

        let dirs = [user, bundled]
        #expect(GhosttyThemeResolver.colorArgs(for: "Mine", dark: false, directories: dirs) == ["background=#111111"])
        #expect(GhosttyThemeResolver.colorArgs(for: "Shipped", dark: false, directories: dirs) == ["background=#333333"])
        #expect(GhosttyThemeResolver.colorArgs(for: "Missing", dark: false, directories: dirs) == nil)

        // Absolute paths and traversal never resolve, even to files that exist.
        let absolute = bundled.appendingPathComponent("Shipped").path
        #expect(GhosttyThemeResolver.colorArgs(for: absolute, dark: false, directories: dirs) == nil)
        #expect(GhosttyThemeResolver.colorArgs(for: "../\(bundled.lastPathComponent)/Shipped", dark: false, directories: [user]) == nil)
        #expect(GhosttyThemeResolver.colorArgs(for: "light:\(absolute),dark:\(absolute)", dark: true, directories: dirs) == nil)
    }

    @Test func refusesFifosDirectoriesAndOversizedFiles() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fifo = dir.appendingPathComponent("Fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(GhosttyThemeResolver.readRegularFile(fifo) == nil)
        #expect(GhosttyThemeResolver.colorArgs(for: "Fifo", dark: false, directories: [dir]) == nil)

        let sub = dir.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(GhosttyThemeResolver.readRegularFile(sub) == nil)

        let big = dir.appendingPathComponent("Big")
        try Data(repeating: 0x41, count: GhosttyThemeResolver.maxFileBytes + 1).write(to: big)
        #expect(GhosttyThemeResolver.readRegularFile(big) == nil)
    }
}
