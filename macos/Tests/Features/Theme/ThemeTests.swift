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

    @Test func strictHexColorRoundTrips() {
        let color = NSColor(strictHex: "#3DDC84")
        #expect(color != nil)
        #expect(color?.hexString == "#3DDC84")
        #expect(NSColor(strictHex: "3DDC84") == nil)
        #expect(NSColor(strictHex: "#3DDC8400") == nil)
    }
}

// MARK: - Applier args

@Suite
struct ThemeApplierArgsTests {
    @Test func emitsThemeFirstThenColorsInFixedOrder() {
        let theme = SurfaceTheme(
            name: "Full",
            ghosttyTheme: "Catppuccin Mocha",
            background: "#010203",
            foreground: "#040506",
            cursorColor: "#070809",
            selectionBackground: "#0A0B0C",
            accent: "#0D0E0F"
        )
        #expect(ThemeApplier.configArgs(for: theme) == [
            "theme=Catppuccin Mocha",
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

    @Test func rejectsThemeNamesWithControlCharacters() {
        let theme = SurfaceTheme(name: "Evil", ghosttyTheme: "Nord\nbackground=#000000")
        #expect(ThemeApplier.configArgs(for: theme).isEmpty)
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
