import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import Ghostty

struct AutocompleteModelTests {
    private func item(
        _ text: String,
        kind: AutocompleteKind = .subcommand,
        dangerous: Bool = false
    ) -> AutocompleteItem {
        AutocompleteItem(text: text, display: text, description: "", kind: kind, dangerous: dangerous, matchLength: 0)
    }

    @Test func sanitizeReplacesControlAndFormatCharacters() {
        #expect(AutocompleteText.sanitize("ok text") == "ok text")
        #expect(AutocompleteText.sanitize("a\u{1b}[31mb") == "a\u{FFFD}[31mb")
        #expect(AutocompleteText.sanitize("\u{202e}gnp.exe") == "\u{FFFD}gnp.exe")
        #expect(AutocompleteText.sanitize("a\u{200b}b") == "a\u{FFFD}b")
        #expect(AutocompleteText.sanitize("line\u{2028}sep") == "line\u{FFFD}sep")
        #expect(AutocompleteText.sanitize("x\u{E000}") == "x\u{FFFD}")
        #expect(AutocompleteText.sanitize("tab\there") == "tab\u{FFFD}here")
        #expect(AutocompleteText.sanitize("ünïcödé 路径 🙂") == "ünïcödé 路径 🙂")
        let long = String(repeating: "a", count: 500)
        #expect(AutocompleteText.sanitize(long).unicodeScalars.count == AutocompleteText.maxDisplayScalars + 1)
    }

    @Test func splitMatchedNeverCutsACharacter() {
        #expect(AutocompleteText.splitMatched("status", matchLength: 3) == ("sta", "tus"))
        #expect(AutocompleteText.splitMatched("status", matchLength: 0) == ("", "status"))
        #expect(AutocompleteText.splitMatched("status", matchLength: 99) == ("status", ""))
        // "é" is two bytes; one byte stops before it.
        #expect(AutocompleteText.splitMatched("éa", matchLength: 1) == ("", "éa"))
        #expect(AutocompleteText.splitMatched("éa", matchLength: 2) == ("é", "a"))
    }

    @Test func dangerousItemsAreNeverPreselected() {
        #expect(AutocompleteSelection.initial([item("a"), item("b")]) == 0)
        #expect(AutocompleteSelection.initial([item("rm", dangerous: true), item("b")]) == 1)
        #expect(AutocompleteSelection.initial([item("rm", dangerous: true)]) == nil)
        #expect(AutocompleteSelection.initial([]) == nil)
    }

    @Test func selectionWraps() {
        #expect(AutocompleteSelection.next(nil, count: 3) == 0)
        #expect(AutocompleteSelection.next(2, count: 3) == 0)
        #expect(AutocompleteSelection.previous(0, count: 3) == 2)
        #expect(AutocompleteSelection.previous(nil, count: 3) == 2)
        #expect(AutocompleteSelection.next(0, count: 0) == nil)
    }

    @Test func bufferSlicingUsesCharacters() {
        let buffer = AutocompleteBuffer(text: "cd é/ü", cursor: 6)
        #expect(buffer.slice(start: 3, length: 3) == "é/ü")
        #expect(buffer.slice(start: 3, length: 99) == "é/ü")
        #expect(buffer.slice(start: 99, length: 1) == "")
        #expect(buffer.cursorAtEnd)
        #expect(!AutocompleteBuffer(text: "git st", cursor: 3).cursorAtEnd)
    }

    @Test func visibilityNeedsASuggestionThatChangesSomething() {
        let buffer = AutocompleteBuffer(text: "git status", cursor: 10)
        let same = AutocompleteSuggestions(
            items: [item("status")], replaceStart: 4, replaceLength: 6, replaceColumns: 6, generation: 1)
        #expect(!AutocompleteVisibility.shouldShow(buffer: buffer, suggestions: same))

        let more = AutocompleteSuggestions(
            items: [item("status"), item("stash")], replaceStart: 4, replaceLength: 6, replaceColumns: 6, generation: 1)
        #expect(AutocompleteVisibility.shouldShow(buffer: buffer, suggestions: more))

        let history = AutocompleteSuggestions(
            items: [item("git status", kind: .history)], replaceStart: 4, replaceLength: 6, replaceColumns: 6, generation: 1)
        #expect(!AutocompleteVisibility.shouldShow(buffer: buffer, suggestions: history))

        let empty = AutocompleteBuffer(text: "", cursor: 0)
        #expect(!AutocompleteVisibility.shouldShow(buffer: empty, suggestions: more))
    }

    private func action(
        _ keyCode: UInt16,
        _ chars: String? = nil,
        _ mods: NSEvent.ModifierFlags = [],
        enter: AutocompleteEnterMode = .accept,
        selection: Bool = true,
        atEnd: Bool = true
    ) -> AutocompleteKeyAction {
        AutocompleteKeys.action(
            keyCode: keyCode, characters: chars, modifiers: mods,
            enterMode: enter, hasSelection: selection, cursorAtEnd: atEnd)
    }

    @Test func keyMapping() {
        #expect(action(AutocompleteKeys.tab) == .next)
        #expect(action(AutocompleteKeys.tab, nil, .shift) == .previous)
        #expect(action(AutocompleteKeys.down) == .next)
        #expect(action(AutocompleteKeys.up) == .previous)
        #expect(action(45, "n", .control) == .next)
        #expect(action(35, "p", .control) == .previous)
        #expect(action(8, "c", .control) == .passthrough)
        #expect(action(AutocompleteKeys.escape) == .dismiss)
        #expect(action(AutocompleteKeys.enter) == .accept)
        #expect(action(AutocompleteKeys.keypadEnter) == .accept)
        #expect(action(AutocompleteKeys.enter, enter: .passthrough) == .passthrough)
        // No selection (all dangerous): Enter goes to the shell.
        #expect(action(AutocompleteKeys.enter, selection: false) == .passthrough)
        #expect(action(AutocompleteKeys.right) == .accept)
        #expect(action(AutocompleteKeys.right, atEnd: false) == .passthrough)
        #expect(action(0, "a") == .passthrough)
        #expect(action(AutocompleteKeys.tab, nil, .command) == .passthrough)
    }

    @Test func cResultConversionCopiesStringsAndAppliesMaxItems() {
        let names: [String] = ["status", "stash", "switch"]
        let texts: [UnsafeMutablePointer<CChar>] = names.map { strdup($0)! }
        defer { texts.forEach { free($0) } }
        var result = ghostty_autocomplete_result_s()
        result.count = 3
        result.replace_start = 4
        result.replace_len = 2
        result.replace_cols = 2
        result.generation = 9
        withUnsafeMutableBytes(of: &result.items) { raw in
            let items = raw.bindMemory(to: ghostty_autocomplete_item_s.self)
            for (index, ptr) in texts.enumerated() {
                items[index].text = UnsafePointer(ptr)
                items[index].text_len = UInt(strlen(ptr))
                items[index].display = UnsafePointer(ptr)
                items[index].display_len = UInt(strlen(ptr))
                items[index].kind = index == 2 ? 4 : 0
                items[index].dangerous = index == 1
                items[index].match_len = 2
            }
        }
        let all = AutocompleteSuggestions(result, maxItems: 8)
        #expect(all.items.map(\.text) == ["status", "stash", "switch"])
        #expect(all.items[1].dangerous)
        #expect(all.items[2].kind == .history)
        #expect(all.items[2].replacesLine)
        #expect(all.items[0].matchLength == 2)
        #expect(all.generation == 9)
        #expect(all.replaceColumns == 2)
        #expect(AutocompleteSuggestions(result, maxItems: 2).items.count == 2)
        #expect(AutocompleteSuggestions(result, maxItems: 0).items.count == 1)
    }

    @Test func dataDirectoryIsXDGAware() {
        let home = "/Users/test"
        #expect(AutocompleteController.dataDirectory(environment: [:], home: home).path
            == "/Users/test/.local/share/slimer")
        #expect(AutocompleteController.dataDirectory(environment: ["XDG_DATA_HOME": "/data"], home: home).path
            == "/data/slimer")
        #expect(AutocompleteController.dataDirectory(environment: ["XDG_DATA_HOME": "rel"], home: home).path
            == "/Users/test/.local/share/slimer")
        #expect(AutocompleteController.dataDirectory(
            environment: ["XCTestConfigurationFilePath": "x"], home: home).path.contains("slimer-xctest-"))
    }
}
