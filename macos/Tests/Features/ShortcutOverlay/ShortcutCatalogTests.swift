import AppKit
import Testing
@testable import Ghostty

struct ShortcutGlyphTests {
    @Test func modifierOrderIsControlOptionShiftCommand() {
        #expect(ShortcutGlyphs.format(keyEquivalent: "t", modifiers: [.command, .shift, .option, .control]) == "⌃⌥⇧⌘T")
        #expect(ShortcutGlyphs.format(keyEquivalent: "t", modifiers: .command) == "⌘T")
    }

    @Test func uppercaseLetterImpliesShift() {
        #expect(ShortcutGlyphs.format(keyEquivalent: "W", modifiers: .command) == "⇧⌘W")
        let (key, mods) = ShortcutGlyphs.normalize(keyEquivalent: "W", modifiers: .command)!
        #expect(key == "w")
        #expect(mods == [.shift, .command])
        // Punctuation has no case and adds nothing.
        #expect(ShortcutGlyphs.format(keyEquivalent: "[", modifiers: .command) == "⌘[")
        #expect(ShortcutGlyphs.format(keyEquivalent: "`", modifiers: .command) == "⌘`")
    }

    @Test func specialKeys() {
        let cases: [(String, String)] = [
            ("\r", "↩"), ("\u{1B}", "⎋"), ("\t", "⇥"), ("\u{8}", "⌫"), ("\u{7F}", "⌫"), (" ", "Space"),
            (String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), "↑"),
            (String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), "↓"),
            (String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!), "←"),
            (String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), "→"),
            (String(UnicodeScalar(UInt16(NSPageUpFunctionKey))!), "⇞"),
            (String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!), "⌦"),
            (String(UnicodeScalar(UInt16(NSF5FunctionKey))!), "F5"),
        ]
        for (input, glyph) in cases {
            #expect(ShortcutGlyphs.keyGlyph(input) == glyph, "\(input.unicodeScalars.map(\.value))")
        }
    }

    @Test func unprintableKeysAreRejected() {
        #expect(ShortcutGlyphs.keyGlyph("\u{1}") == nil)
        #expect(ShortcutGlyphs.keyGlyph("\u{202E}") == nil)
        #expect(ShortcutGlyphs.keyGlyph("") == nil)
        #expect(ShortcutGlyphs.keyGlyph("ab") == nil)
        #expect(ShortcutGlyphs.format(keyEquivalent: "", modifiers: .command) == nil)
    }
}

struct ShortcutCatalogTests {
    private func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        return item
    }

    private func top(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = menu
        return top
    }

    private func mainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        main.addItem(top("", [item("About", ""), item("Quit Slimer", "q")]))

        let hidden = item("Hidden", "h")
        hidden.isHidden = true
        let disabled = item("Close Tab", "W")
        disabled.isEnabled = false
        let nested = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
        let nestedMenu = NSMenu(title: "Claude")
        nestedMenu.addItem(item("New Session", "c", [.command, .option]))
        nested.submenu = nestedMenu
        main.addItem(top("File", [
            item("New Tab", "t"), .separator(), hidden, disabled, nested,
            item("Duplicate New Tab", "t"),
            item("Bad\u{1B}[31m Title\u{202E}", "b"),
        ]))
        main.addItem(top("Empty", [item("No shortcut", "")]))
        return main
    }

    @Test func groupsByTopLevelMenuAndSkipsSeparatorsAndHidden() {
        var chords = Set<ShortcutChord>()
        let groups = ShortcutCatalog.menuGroups(from: mainMenu(), appName: "Slimer", chords: &chords)
        #expect(groups.map(\.title) == ["Slimer", "File"])
        #expect(groups[0].entries == [ShortcutEntry(title: "Quit Slimer", keys: "⌘Q")])
        #expect(groups[1].entries.map(\.title) == ["New Tab", "Close Tab", "New Session", "Bad[31m Title"])
        #expect(groups[1].entries.map(\.keys) == ["⌘T", "⇧⌘W", "⌥⌘C", "⌘B"])
        #expect(groups[1].entries[1].isEnabled == false)
        #expect(groups[1].entries[0].isEnabled == true)
        #expect(chords.contains(ShortcutChord(modifiers: [.shift, .command], key: "w")))
        #expect(!chords.contains(ShortcutChord(modifiers: .command, key: "h")))
    }

    @Test func skippedMenusAreNotWalked() {
        let main = mainMenu()
        let file = main.items[1].submenu!
        var chords = Set<ShortcutChord>()
        let groups = ShortcutCatalog.menuGroups(
            from: main, appName: "Slimer", skipping: [ObjectIdentifier(file)], chords: &chords)
        #expect(groups.map(\.title) == ["Slimer"])
    }

    @Test func displayTitleStripsControlsAndTruncates() {
        #expect(ShortcutCatalog.displayTitle("a\u{0}b\u{7F}c\u{2028}d") == "abcd")
        #expect(ShortcutCatalog.displayTitle("  two   words \n") == "two words")
        let long = String(repeating: "x", count: 60)
        let short = ShortcutCatalog.displayTitle(long)
        #expect(short.count == ShortcutCatalog.maxTitleLength)
        #expect(short.hasSuffix("…"))
    }

    @Test func keybindsOnAMenuAreLeftOutButGlobalsStay() {
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        let binds: [ShortcutCatalog.Keybind] = [
            .init(keyEquivalent: "t", modifiers: .command, action: "new_tab", isGlobal: false),
            .init(keyEquivalent: up, modifiers: [.command, .option], action: "goto_split:up", isGlobal: false),
            .init(keyEquivalent: "=", modifiers: [.command, .control], action: "equalize_splits", isGlobal: false),
            .init(keyEquivalent: "`", modifiers: .command, action: "toggle_quick_terminal", isGlobal: true),
            .init(keyEquivalent: "x", modifiers: .command, action: "ignore", isGlobal: false),
            .init(keyEquivalent: "y", modifiers: .command, action: "toggle_tab_overview", isGlobal: false),
            .init(keyEquivalent: "z", modifiers: .control, action: "text:\u{1B}evil", isGlobal: false),
        ]
        let menuChords: Set<ShortcutChord> = [
            ShortcutChord(modifiers: .command, key: "t"),
            ShortcutChord(modifiers: .command, key: "`"),
        ]
        let groups = ShortcutCatalog.keybindGroups(
            binds,
            menuChords: menuChords,
            titles: ["goto_split:up": "Focus Split: Up"],
            unsupportedActionKeys: ["toggle_tab_overview"])
        #expect(groups.map(\.title) == ["Global", "Keybinds"])
        #expect(groups[0].entries == [ShortcutEntry(title: "Toggle quick terminal", keys: "⌘`", isGlobal: true)])
        #expect(groups[1].entries.map(\.title) == ["Equalize splits", "Focus Split: Up", "Text: evil"])
        #expect(groups[1].entries.map(\.keys) == ["⌃⌘=", "⌥⌘↑", "⌃Z"])
    }

    @Test func humanize() {
        #expect(ShortcutCatalog.humanize("goto_split:left") == "Goto split: left")
        #expect(ShortcutCatalog.humanize("equalize_splits") == "Equalize splits")
        #expect(ShortcutCatalog.humanize("resize_split:up,10") == "Resize split: up,10")
    }
}

struct ShortcutOverlayLayoutTests {
    private func group(_ title: String, _ count: Int) -> ShortcutGroup {
        ShortcutGroup(title: title, entries: (0..<count).map { ShortcutEntry(title: "\(title)\($0)", keys: "⌘\($0)") })
    }

    @Test func packsGroupsIntoColumns() {
        let result = ShortcutOverlayLayout.pack([group("A", 3), group("B", 3), group("C", 3)], maxRows: 10, maxColumns: 4)
        // Each group costs 2 header rows + 3 entries = 5 rows.
        #expect(result.columns.map { $0.map(\.title) } == [["A", "B"], ["C"]])
        #expect(result.hiddenCount == 0)
    }

    @Test func splitsTallGroupsAndCountsOverflow() {
        let result = ShortcutOverlayLayout.pack([group("A", 20)], maxRows: 10, maxColumns: 2)
        #expect(result.columns.map { $0.map(\.title) } == [["A"], ["A (cont.)"]])
        #expect(result.columns.flatMap { $0 }.map(\.entries.count) == [8, 8])
        #expect(result.hiddenCount == 4)
    }

    @Test func emptyGroupsAreDropped() {
        let result = ShortcutOverlayLayout.pack([group("A", 0), group("B", 1)], maxRows: 10, maxColumns: 1)
        #expect(result.columns.map { $0.map(\.title) } == [["B"]])
    }
}

struct ShortcutOverlayConfigTests {
    @Test func modifiers() {
        #expect(Ghostty.Config.SlimerShortcutOverlay.ctrl.modifier == .control)
        #expect(Ghostty.Config.SlimerShortcutOverlay.cmd.modifier == .command)
        #expect(Ghostty.Config.SlimerShortcutOverlay.option.modifier == .option)
        #expect(Ghostty.Config.SlimerShortcutOverlay.off.modifier == nil)
    }

    @Test func delayIsClampedTo250Milliseconds() {
        #expect(Ghostty.Config.slimerShortcutOverlayDelay(milliseconds: 0) == 0.25)
        #expect(Ghostty.Config.slimerShortcutOverlayDelay(milliseconds: 100) == 0.25)
        #expect(Ghostty.Config.slimerShortcutOverlayDelay(milliseconds: 250) == 0.25)
        #expect(Ghostty.Config.slimerShortcutOverlayDelay(milliseconds: 1500) == 1.5)
        #expect(Ghostty.Config.slimerShortcutOverlayDelay(milliseconds: 2000) == 2)
    }

    @Test func settingsAcceptOnlyKnownValues() throws {
        #expect(try SettingsValidator.validate(key: "slimer-shortcut-overlay", value: "cmd").get() == "cmd")
        #expect((try? SettingsValidator.validate(key: "slimer-shortcut-overlay", value: "shift").get()) == nil)
        #expect(try SettingsValidator.validate(key: "slimer-shortcut-overlay-delay", value: "1500ms").get() == "1500ms")
        #expect((try? SettingsValidator.validate(key: "slimer-shortcut-overlay-delay", value: "1h").get()) == nil)
    }
}
