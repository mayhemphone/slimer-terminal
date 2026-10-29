import Foundation
import Testing
@testable import Ghostty

/// Slimer: the Settings store end to end against a temp config file (no app config,
/// no real reload).
@MainActor
struct SettingsConfigStoreTests {
    private func makeStore(_ text: String) throws -> (SettingsConfigStore, URL, () -> Int) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config")
        try text.write(to: url, atomically: false, encoding: .utf8)
        let store = SettingsConfigStore()
        var reloads = 0
        store.reloadConfig = { reloads += 1 }
        store.currentConfig = { nil }
        store.load(url: url)
        return (store, url, { reloads })
    }

    @Test func writesValidatedValuesAndReloads() throws {
        let (store, url, reloads) = try makeStore("font-size = 14\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        store.set("quick-terminal-position", "right")
        store.set("quick-terminal-animation-duration", "0.250")
        store.set("font-family", "JetBrains Mono")
        store.set("quick-terminal-position", "sideways")   // rejected, previous value kept
        #expect(store.hasPendingWrite)
        #expect(store.fieldErrors["quick-terminal-position"] != nil)
        store.flush()

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == """
        font-size = 14

        \(GhosttyConfigWriter.beginMarker)
        quick-terminal-position = right
        quick-terminal-animation-duration = 0.25
        font-family = ""
        font-family = JetBrains Mono
        \(GhosttyConfigWriter.endMarker)

        """)
        #expect(reloads() == 1)
        #expect(store.displayValue(for: "font-family") == "JetBrains Mono")
        #expect(FileManager.default.fileExists(atPath: url.path + ".slimer-backup"))
    }

    @Test func clearingLastKeyRemovesBlock() throws {
        let (store, url, _) = try makeStore("a = 1\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.set("theme", "Nord")
        store.flush()
        store.set("theme", nil)
        store.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "a = 1\n\n")
    }

    @Test func malformedBlockIsNeverWritten() throws {
        let original = "\(GhosttyConfigWriter.beginMarker)\ntheme = Nord\n"
        let (store, url, reloads) = try makeStore(original)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(store.fileError != nil)
        store.set("theme", "Dracula")
        store.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
        #expect(reloads() == 0)
    }

    @Test func handEditsMadeMeanwhileSurvive() throws {
        let (store, url, _) = try makeStore("a = 1\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.set("theme", "Nord")
        // The user edits the file before the debounce fires.
        try "a = 2\nb = 3\n".write(to: url, atomically: true, encoding: .utf8)
        store.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("a = 2\nb = 3\n\n"))
        #expect(text.contains("theme = Nord"))
    }

    @Test func warnsAboutOverrideAfterBlock() throws {
        let text = "\(GhosttyConfigWriter.beginMarker)\ntheme = Nord\n\(GhosttyConfigWriter.endMarker)\ntheme = Dracula\n"
        let (store, url, _) = try makeStore(text)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(store.isOverridden("theme"))
        #expect(store.findings(for: "theme").first?.message == "Your config sets theme on line 4 after Slimer's block; Settings can't change it.")
    }

    @Test func globalKeybindReplacesUsersTrigger() throws {
        let (store, url, _) = try makeStore("keybind = global:cmd+backquote=toggle_quick_terminal\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(store.effectiveTrigger(for: .toggleQuickTerminal).trigger == "cmd+backquote")
        #expect(store.effectiveTrigger(for: .toggleQuickTerminal).fromUserLine == 1)

        store.setGlobalKeybind(.toggleQuickTerminal, .set("cmd+f1"))
        store.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("keybind = global:cmd+backquote=unbind\nkeybind = global:cmd+f1=toggle_quick_terminal\n"))
        #expect(text.hasPrefix("keybind = global:cmd+backquote=toggle_quick_terminal\n"))

        // Reloading from disk gives the same state back.
        store.load()
        #expect(store.globalKeybinds[.toggleQuickTerminal] == .set("cmd+f1"))
    }
}
