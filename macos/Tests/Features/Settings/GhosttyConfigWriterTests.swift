import Testing
import Foundation
@testable import Ghostty

/// Slimer: the managed block in the Ghostty config file. Pure text in, text out.
struct GhosttyConfigWriterTests {
    typealias Writer = GhosttyConfigWriter
    typealias Entry = GhosttyConfigWriter.Entry

    private let begin = GhosttyConfigWriter.beginMarker
    private let end = GhosttyConfigWriter.endMarker

    // MARK: Insert

    @Test func appendsBlockAfterBlankLine() throws {
        let text = "font-size = 14\n"
        let out = try Writer.render(text: text, entries: [Entry("quick-terminal-position", ["right"])])
        #expect(out == "font-size = 14\n\n\(begin)\nquick-terminal-position = right\n\(end)\n")
    }

    @Test func insertsIntoEmptyFile() throws {
        let out = try Writer.render(text: "", entries: [Entry("theme", ["Nord"])])
        #expect(out == "\(begin)\ntheme = Nord\n\(end)\n")
    }

    @Test func noTrailingNewlineGetsOneBeforeBlock() throws {
        let out = try Writer.render(text: "font-size = 14", entries: [Entry("theme", ["Nord"])])
        #expect(out == "font-size = 14\n\n\(begin)\ntheme = Nord\n\(end)\n")
    }

    @Test func doesNotAddSecondBlankLine() throws {
        let out = try Writer.render(text: "a = 1\n\n", entries: [Entry("theme", ["Nord"])])
        #expect(out == "a = 1\n\n\(begin)\ntheme = Nord\n\(end)\n")
    }

    @Test func noEntriesNoBlock() throws {
        #expect(try Writer.render(text: "a = 1\n", entries: []) == "a = 1\n")
        #expect(try Writer.render(text: "a = 1\n", entries: [Entry("theme", [])]) == "a = 1\n")
    }

    // MARK: Replace

    @Test func replacesExistingBlockInPlace() throws {
        let text = "# mine\na = 1\n\(begin)\ntheme = Nord\n\(end)\nb = 2\n"
        let out = try Writer.render(text: text, entries: [Entry("theme", ["Dracula"]), Entry("font-size", ["13"])])
        #expect(out == "# mine\na = 1\n\(begin)\ntheme = Dracula\nfont-size = 13\n\(end)\nb = 2\n")
    }

    @Test func removesBlockWhenEmpty() throws {
        let text = "a = 1\n\(begin)\ntheme = Nord\n\(end)\nb = 2\n"
        #expect(try Writer.render(text: text, entries: []) == "a = 1\nb = 2\n")
    }

    @Test func renderIsIdempotent() throws {
        let entries = [Entry("theme", ["Nord"]), Entry("keybind", ["global:cmd+backquote=toggle_quick_terminal"])]
        let once = try Writer.render(text: "a = 1\n", entries: entries)
        #expect(try Writer.render(text: once, entries: entries) == once)
    }

    @Test func markersWithSurroundingWhitespaceAreRecognized() throws {
        let text = "  \(begin)  \ntheme = Nord\n\(end)\t\n"  // markers are kept verbatim
        #expect(try Writer.render(text: text, entries: [Entry("theme", ["X"])]) == "  \(begin)  \ntheme = X\n\(end)\t\n")
    }

    // MARK: Preserve

    @Test func preservesEveryLineOutsideBlockByteForByte() throws {
        let before = "# comment = not a key\n\n  font-family = \"Fira Code\"  \n\tkeybind = cmd+t=new_tab\nweird line without equals\n"
        let after = "theme = light:A,dark:B\n# trailing comment"
        let text = before + "\(begin)\ntheme = Nord\n\(end)\n" + after
        let out = try Writer.render(text: text, entries: [Entry("font-size", ["20"])])
        #expect(out == before + "\(begin)\nfont-size = 20\n\(end)\n" + after)
    }

    @Test func keepsMissingTrailingNewlineAfterBlock() throws {
        let text = "\(begin)\ntheme = Nord\n\(end)"
        #expect(try Writer.render(text: text, entries: [Entry("theme", ["X"])]) == "\(begin)\ntheme = X\n\(end)")
    }

    // MARK: CRLF

    @Test func crlfFileUsesCRLFForBlock() throws {
        let text = "a = 1\r\nb = 2\r\n"
        let out = try Writer.render(text: text, entries: [Entry("theme", ["Nord"])])
        #expect(out == "a = 1\r\nb = 2\r\n\r\n\(begin)\r\ntheme = Nord\r\n\(end)\r\n")
    }

    @Test func crlfBlockIsReplaced() throws {
        let text = "a = 1\r\n\(begin)\r\ntheme = Nord\r\n\(end)\r\nb = 2\r\n"
        let out = try Writer.render(text: text, entries: [Entry("theme", ["X"])])
        #expect(out == "a = 1\r\n\(begin)\r\ntheme = X\r\n\(end)\r\nb = 2\r\n")
        #expect(try Writer.managedEntries(in: text) == [Entry("theme", ["Nord"])])
    }

    // MARK: Repeatable keys

    @Test func repeatableKeybindsKeepOrder() throws {
        let binds = [
            "global:cmd+backquote=unbind",
            "global:cmd+f1=toggle_quick_terminal",
            "global:cmd+shift+n=new_window",
        ]
        let out = try Writer.render(text: "", entries: [Entry("keybind", binds)])
        #expect(out == "\(begin)\n" + binds.map { "keybind = \($0)" }.joined(separator: "\n") + "\n\(end)\n")
        #expect(try Writer.managedEntries(in: out) == [Entry("keybind", binds)])
    }

    @Test func managedEntriesStripQuotes() throws {
        let text = "\(begin)\nfont-family = \"\"\nfont-family = JetBrains Mono\n\(end)\n"
        #expect(try Writer.managedEntries(in: text) == [Entry("font-family", ["", "JetBrains Mono"])])
    }

    // MARK: Refusals

    @Test func refusesNewlineAndControlValues() {
        for bad in ["a\nb", "a\rb", "x\u{0}", "tab\there", "\u{7F}", "\u{85}", "a\u{2028}b", "", " padded", "padded "] {
            #expect(throws: GhosttyConfigWriter.WriteError.invalidValue(key: "theme", value: bad)) {
                try Writer.render(text: "", entries: [Entry("theme", [bad])])
            }
        }
    }

    @Test func refusesBadKeys() {
        for bad in ["", "Theme", "a b", "a=b", "x\n"] {
            #expect(throws: GhosttyConfigWriter.WriteError.invalidKey(bad)) {
                try Writer.render(text: "", entries: [Entry(bad, ["1"])])
            }
        }
    }

    @Test func refusesMalformedBlocks() {
        let cases = [
            "\(begin)\ntheme = Nord\n",                                 // no end
            "theme = Nord\n\(end)\n",                                   // no begin
            "\(end)\n\(begin)\n",                                       // reversed
            "\(begin)\n\(end)\n\(begin)\n\(end)\n",                     // two blocks
        ]
        for text in cases {
            #expect(throws: GhosttyConfigWriter.WriteError.self) {
                try Writer.render(text: text, entries: [Entry("theme", ["X"])])
            }
        }
    }

    // MARK: Analysis

    @Test func detectsOverrideAfterBlock() throws {
        let text = "theme = A\n\(begin)\ntheme = B\n\(end)\nfont-size = 3\ntheme = C\n"
        let findings = try Writer.analyze(text: text, keys: ["theme"])
        #expect(findings.map(\.kind) == [.setBefore, .overriddenAfter])
        #expect(findings.last?.line == 6)
        #expect(findings.last?.message == "Your config sets theme on line 6 after Slimer's block; Settings can't change it.")
    }

    @Test func withoutBlockEverythingIsBefore() throws {
        let findings = try Writer.analyze(text: "theme = A\ntheme = B\n", keys: ["theme"])
        #expect(findings.map(\.kind) == [.setBefore, .setBefore])
    }

    @Test func fontFamilyAfterBlockAppendsUnlessReset() throws {
        let text = "\(begin)\nfont-family = \"\"\nfont-family = A\n\(end)\nfont-family = B\nfont-family = \"\"\n"
        let findings = try Writer.analyze(text: text, keys: ["font-family"])
        #expect(findings.map(\.kind) == [.addsAfter, .overriddenAfter])
    }

    @Test func keybindAfterBlockMatchedByTriggerOrAction() throws {
        let managed = ["global:cmd+backquote=toggle_quick_terminal"]
        let text = """
        \(begin)
        keybind = global:cmd+backquote=toggle_quick_terminal
        \(end)
        keybind = cmd+t=new_tab
        keybind = global:shift+cmd+backquote=new_window
        keybind = command+backquote=new_tab
        keybind = global:f5=toggle_quick_terminal
        keybind = clear

        """
        let findings = try Writer.analyze(text: text, keys: ["keybind"], managedKeybinds: managed)
        #expect(findings.map(\.line) == [6, 7, 8])
        #expect(findings.map(\.kind) == [.overriddenAfter, .addsAfter, .overriddenAfter])
    }

    @Test func reportsIncludes() throws {
        let findings = try Writer.analyze(text: "config-file = ?extra\n", keys: ["theme"])
        #expect(findings.map(\.kind) == [.include])
        #expect(findings.first?.value == "?extra")
    }

    @Test func ignoresUnrelatedKeysAndComments() throws {
        let text = "# theme = X\nfont-size = 3\n\(begin)\n\(end)\n#theme = Y\n"
        #expect(try Writer.analyze(text: text, keys: ["theme"]).isEmpty)
    }

    // MARK: Foreign lines inside the block

    @Test func keepsForeignBlockLinesVerbatimAndInPlace() throws {
        let text = """
        a = 1
        \(begin)
        # a note I wrote
        theme = Old
        slimer-future-key = 7
        keybind = cmd+k=clear_screen
        keybind = global:cmd+j=toggle_quick_terminal
        keybind = global:cmd+o=unbind
        keybind = global:cmd+u=goto_tab:1
          font-size =  12
        \(end)

        """
        let out = try Writer.render(text: text, entries: [
            Entry("theme", ["New"]),
            Entry("keybind", ["global:cmd+f1=toggle_quick_terminal"]),
            Entry("quick-terminal-position", ["right"]),
        ], owns: SettingsKeySpec.owns)
        #expect(out == """
        a = 1
        \(begin)
        # a note I wrote
        theme = New
        slimer-future-key = 7
        keybind = cmd+k=clear_screen
        keybind = global:cmd+f1=toggle_quick_terminal
        keybind = global:cmd+u=goto_tab:1
        quick-terminal-position = right
        \(end)

        """)
        // Only owned lines are read back as managed.
        #expect(try Writer.managedEntries(in: text, owns: SettingsKeySpec.owns) == [
            Entry("theme", ["Old"]),
            Entry("keybind", ["global:cmd+j=toggle_quick_terminal", "global:cmd+o=unbind"]),
            Entry("font-size", ["12"]),
        ])
    }

    @Test func blockWithOnlyForeignLinesIsKept() throws {
        let text = "\(begin)\n# keep me\ntheme = Nord\n\(end)\n"
        #expect(try Writer.render(text: text, entries: [], owns: SettingsKeySpec.owns)
                == "\(begin)\n# keep me\n\(end)\n")
        let blankOnly = "x = 1\n\(begin)\n\ntheme = Nord\n\(end)\n"
        #expect(try Writer.render(text: blankOnly, entries: [], owns: SettingsKeySpec.owns) == "x = 1\n")
    }

    // MARK: Terminators and BOM

    @Test func keepsEachLinesTerminatorAndUsesMajorityForNewLines() throws {
        let text = "a = 1\r\nb = 2\r\nc = 3\n"
        let out = try Writer.render(text: text, entries: [Entry("theme", ["Nord"])])
        #expect(out == "a = 1\r\nb = 2\r\nc = 3\n\r\n\(begin)\r\ntheme = Nord\r\n\(end)\r\n")

        let mixedBlock = "x\n\(begin)\r\ntheme = A\n\(end)\r\ny\r\n"
        let replaced = try Writer.render(text: mixedBlock, entries: [Entry("theme", ["B"])])
        // Majority is CRLF (3 of 5); the markers and outside lines keep their own endings.
        #expect(replaced == "x\n\(begin)\r\ntheme = B\r\n\(end)\r\ny\r\n")
    }

    @Test func keepsBOM() throws {
        let text = "\u{FEFF}a = 1\n"
        let out = try Writer.render(text: text, entries: [Entry("theme", ["Nord"])])
        #expect(out == "\u{FEFF}a = 1\n\n\(begin)\ntheme = Nord\n\(end)\n")
        #expect(try Writer.render(text: out, entries: [Entry("theme", ["X"])]).hasPrefix("\u{FEFF}a = 1\n"))
        #expect(Writer.split(text).lines.first?.content == "a = 1")
    }

    @Test func keepsTrailingLoneCR() throws {
        let text = "\(begin)\ntheme = A\n\(end)\r"
        #expect(try Writer.render(text: text, entries: [Entry("theme", ["B"])]) == "\(begin)\ntheme = B\n\(end)\r")
        let lines = Writer.split("a\r")
        #expect(lines.lines == [GhosttyConfigWriter.Line(content: "a", terminator: "\r")])
        #expect(lines.joined() == "a\r")
        #expect(try Writer.render(text: "a = 1\r", entries: [Entry("theme", ["B"])])
                == "a = 1\r\n\n\(begin)\ntheme = B\n\(end)\n")
    }

    @Test func splitJoinRoundTrips() {
        for text in ["", "a", "a\n", "a\r\n", "a\r", "\n\n", "\u{FEFF}x\r\ny\nz", "a\rb\n"] {
            #expect(Writer.split(text).joined() == text, "\(text.debugDescription)")
        }
    }

    // MARK: Long lines

    @Test func warnsAboutOverlongLineBeforeBlock() throws {
        let long = "font-family = " + String(repeating: "x", count: 4100)
        let findings = try Writer.analyze(text: "a = 1\n\(long)\n\(begin)\n\(end)\n", keys: [])
        #expect(findings.map(\.kind) == [.longLine])
        #expect(findings.first?.line == 2)
        // After the block it doesn't hide the block.
        #expect(try Writer.analyze(text: "\(begin)\n\(end)\n\(long)\n", keys: []).isEmpty)
        // Exactly the limit is fine.
        let edge = String(repeating: "y", count: GhosttyConfigWriter.maxLineBytes)
        #expect(try Writer.analyze(text: "\(edge)\n", keys: []).isEmpty)
    }

    // MARK: Keybind parsing

    @Test func parsesKeybindValues() {
        let v = KeybindValue(parsing: "global:cmd+backquote=toggle_quick_terminal")
        #expect(v?.prefixes == ["global"])
        #expect(v?.trigger == "cmd+backquote")
        #expect(v?.action == "toggle_quick_terminal")

        let eq = KeybindValue(parsing: "cmd+==increase_font_size:1")
        #expect(eq?.trigger == "cmd+=")
        #expect(eq?.actionName == "increase_font_size")

        #expect(KeybindValue(parsing: "shift+super+a=x")?.normalizedTrigger == "cmd+shift+a")
        #expect(KeybindValue(parsing: "clear") == nil)
    }
}
