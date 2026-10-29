import AppKit
import Foundation
import Testing
@testable import Ghostty

/// Slimer: the Settings store end to end against temp config files (no app config, no
/// real reload, no real default files).
@MainActor
struct SettingsConfigStoreTests {
    /// Stands in for `NSApplication.willTerminateNotification` so the test host's own
    /// observers don't see a quit.
    static let quitting = Notification.Name("SlimerSettingsTestsWillTerminate")

    private struct Fixture {
        var store: SettingsConfigStore
        var dir: URL
        var url: URL
        var reloads: () -> Int

        func text() throws -> String { try String(contentsOf: url, encoding: .utf8) }
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// The edited file is `<tmp>/ghostty/config` with XDG_CONFIG_HOME = `<tmp>`, so it is a
    /// default file and `<tmp>/ghostty/config.ghostty` loads after it.
    private func makeStore(_ text: String, extraFiles: [String: String] = [:]) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-store-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let ghostty = dir.appendingPathComponent("ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: ghostty, withIntermediateDirectories: true)
        let url = ghostty.appendingPathComponent("config")
        try text.write(to: url, atomically: false, encoding: .utf8)
        for (name, contents) in extraFiles {
            try contents.write(to: ghostty.appendingPathComponent(name), atomically: false, encoding: .utf8)
        }
        let store = SettingsConfigStore(terminationNotification: Self.quitting)
        var reloads = 0
        store.reloadConfig = { reloads += 1 }
        store.currentConfig = { nil }
        store.environment = ["XDG_CONFIG_HOME": dir.path]
        store.appSupportDirectory = dir.appendingPathComponent("appsupport", isDirectory: true)
        store.load(url: url, synchronously: true)
        return Fixture(store: store, dir: dir, url: url, reloads: { reloads })
    }

    @Test func writesValidatedValuesAndReloads() throws {
        let fx = try makeStore("font-size = 14\n")
        defer { fx.cleanup() }
        let store = fx.store

        store.set("quick-terminal-position", "right")
        store.set("quick-terminal-animation-duration", "0.250")
        store.set("font-family", "JetBrains Mono")
        store.set("quick-terminal-position", "sideways")   // rejected, previous value kept
        #expect(store.hasPendingWrite)
        #expect(store.fieldErrors["quick-terminal-position"] != nil)
        store.flush()

        #expect(try fx.text() == """
        font-size = 14

        \(GhosttyConfigWriter.beginMarker)
        quick-terminal-position = right
        quick-terminal-animation-duration = 0.25
        font-family = ""
        font-family = JetBrains Mono
        \(GhosttyConfigWriter.endMarker)

        """)
        #expect(fx.reloads() == 1)
        #expect(store.displayValue(for: "font-family") == "JetBrains Mono")
        #expect(store.file?.backups().count == 1)

        // A second write that keeps the block doesn't add another backup.
        store.set("theme", "Nord")
        store.flush()
        #expect(store.file?.backups().count == 1)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func arrowingThroughThemesWritesOnceAfterAPause() async throws {
        let original = "font-size = 14\n"
        let fx = try makeStore(original)
        defer { fx.cleanup() }
        let store = fx.store
        // Capture the debounce instead of waiting on the clock, so a loaded test machine
        // can't fire a timer early or late.
        var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
        store.scheduleDebounced = { scheduled.append(($0, $1)) }

        // Arrowing through the list: each move applies at once in Settings and restarts
        // the debounce.
        for name in ["Nord", "Dracula", "Solarized Dark", "Tomorrow"] {
            store.set("theme", name)
            #expect(store.displayValue(for: "theme") == name)
        }
        #expect(scheduled.count == 4)
        #expect(scheduled.allSatisfy { $0.delay >= 0.4 })
        #expect(scheduled.dropLast().allSatisfy { $0.work.isCancelled })
        #expect(try fx.text() == original)
        #expect(fx.reloads() == 0)
        #expect(store.hasPendingWrite)

        // Only the last timer is live; it writes once, with the last value.
        for item in scheduled where !item.work.isCancelled { item.work.perform() }
        try await waitUntil { fx.reloads() > 0 }
        #expect(fx.reloads() == 1)
        let text = try fx.text()
        #expect(text.contains("theme = Tomorrow"))
        #expect(!text.contains("Nord") && !text.contains("Dracula"))
        #expect(store.file?.backups().count == 1)
    }

    @Test func repeatedBlockChurnNeverLosesTheOriginalBackup() throws {
        let original = "font-size = 14\n# my own config\n"
        let fx = try makeStore(original)
        defer { fx.cleanup() }

        // Clearing and re-adding the block would back up the file each time; one store
        // (one Settings session) backs up a file at most once.
        for n in 0..<6 {
            fx.store.set("theme", "Theme\(n)")
            fx.store.flush()
            fx.store.set("theme", nil)
            fx.store.flush()
        }
        var backups = try #require(fx.store.file?.backups())
        #expect(backups.count == 1)
        #expect(try String(contentsOf: backups[0], encoding: .utf8) == original)

        // Later sessions add backups of their own, but the original stays the oldest.
        for n in 0..<4 {
            let store = SettingsConfigStore(terminationNotification: Self.quitting)
            store.reloadConfig = {}
            store.currentConfig = { nil }
            store.environment = fx.store.environment
            store.appSupportDirectory = fx.store.appSupportDirectory
            store.load(url: fx.url, synchronously: true)
            store.set("theme", "Later\(n)")
            store.flush()
            store.set("theme", nil)
            store.flush()
        }
        backups = try #require(fx.store.file?.backups())
        #expect(backups.count <= GhosttyConfigFile.backupsKept)
        #expect(try String(contentsOf: backups[0], encoding: .utf8) == original)
    }

    @Test func clearingLastKeyRemovesBlock() throws {
        let fx = try makeStore("a = 1\n")
        defer { fx.cleanup() }
        fx.store.set("theme", "Nord")
        fx.store.flush()
        fx.store.set("theme", nil)
        fx.store.flush()
        #expect(try fx.text() == "a = 1\n\n")
    }

    @Test func preservesForeignLinesInBlockThroughEdits() throws {
        let original = """
        \(GhosttyConfigWriter.beginMarker)
        # synced from a newer Slimer
        slimer-future = on
        theme = Nord
        keybind = cmd+k=clear_screen
        \(GhosttyConfigWriter.endMarker)

        """
        let fx = try makeStore(original)
        defer { fx.cleanup() }
        #expect(fx.store.managed == ["theme": ["Nord"]])
        fx.store.set("theme", "Dracula")
        fx.store.flush()
        #expect(try fx.text() == original.replacingOccurrences(of: "theme = Nord", with: "theme = Dracula"))
    }

    @Test func malformedBlockIsNeverWritten() throws {
        let original = "\(GhosttyConfigWriter.beginMarker)\ntheme = Nord\n"
        let fx = try makeStore(original)
        defer { fx.cleanup() }
        #expect(fx.store.fileError != nil)
        fx.store.set("theme", "Dracula")
        fx.store.flush()
        #expect(try fx.text() == original)
        #expect(fx.reloads() == 0)
    }

    @Test func handEditsMadeMeanwhileSurvive() throws {
        let fx = try makeStore("a = 1\n")
        defer { fx.cleanup() }
        fx.store.set("theme", "Nord")
        // The user edits the file before the debounce fires.
        try "a = 2\nb = 3\n".write(to: fx.url, atomically: true, encoding: .utf8)
        fx.store.flush()
        let text = try fx.text()
        #expect(text.hasPrefix("a = 2\nb = 3\n\n"))
        #expect(text.contains("theme = Nord"))
    }

    @Test func refusesToRecreateFileThatVanished() throws {
        let fx = try makeStore("a = 1\n")
        defer { fx.cleanup() }
        fx.store.set("theme", "Nord")
        // An editor's rename-write-delete save is half done: the file is gone.
        try FileManager.default.removeItem(at: fx.url)
        fx.store.flush()
        #expect(!FileManager.default.fileExists(atPath: fx.url.path))
        #expect(fx.store.fileError?.contains("disappeared") == true)
        #expect(fx.reloads() == 0)
    }

    @Test func warnsAboutOverrideAfterBlock() throws {
        let text = "\(GhosttyConfigWriter.beginMarker)\ntheme = Nord\n\(GhosttyConfigWriter.endMarker)\ntheme = Dracula\n"
        let fx = try makeStore(text)
        defer { fx.cleanup() }
        #expect(fx.store.isOverridden("theme"))
        #expect(fx.store.findings(for: "theme").first?.message == "Your config sets theme on line 4 after Slimer's block; Settings can't change it.")
    }

    @Test func globalKeybindReplacesUsersTrigger() throws {
        let fx = try makeStore("keybind = global:cmd+backquote=toggle_quick_terminal\n")
        defer { fx.cleanup() }
        let store = fx.store
        #expect(store.effectiveTrigger(for: .toggleQuickTerminal).trigger == "cmd+backquote")
        #expect(store.effectiveTrigger(for: .toggleQuickTerminal).fromUserLine == 1)

        store.setGlobalKeybind(.toggleQuickTerminal, .set("cmd+f1"))
        store.flush()
        let text = try fx.text()
        #expect(text.contains("keybind = global:cmd+backquote=unbind\nkeybind = global:cmd+f1=toggle_quick_terminal\n"))
        #expect(text.hasPrefix("keybind = global:cmd+backquote=toggle_quick_terminal\n"))

        // Reloading from disk gives the same state back.
        store.load(synchronously: true)
        #expect(store.globalKeybinds[.toggleQuickTerminal] == .set("cmd+f1"))
        #expect(!store.hasPendingWrite)
    }

    @Test func deniedGlobalHotkeyIsNotWritten() throws {
        let fx = try makeStore("")
        defer { fx.cleanup() }
        fx.store.setGlobalKeybind(.newWindow, .set("cmd+c"))
        #expect(fx.store.fieldErrors["keybind"] != nil)
        #expect(!fx.store.hasPendingWrite)
    }

    @Test func staleUnbindIsDroppedOnLoad() throws {
        // The user deleted their `global:cmd+backquote=…` line; the unbind is now stale and
        // would kill any later binding on ⌘`.
        let text = """
        \(GhosttyConfigWriter.beginMarker)
        keybind = global:cmd+backquote=unbind
        keybind = global:cmd+f1=toggle_quick_terminal
        \(GhosttyConfigWriter.endMarker)
        """
        let fx = try makeStore(text + "\n")
        defer { fx.cleanup() }
        #expect(fx.store.hasPendingWrite)
        #expect(fx.store.managed["keybind"] == ["global:cmd+f1=toggle_quick_terminal"])
        fx.store.flush()
        let written = try fx.text()
        #expect(!written.contains("unbind"))
        #expect(written.contains("keybind = global:cmd+f1=toggle_quick_terminal"))
    }

    @Test func otherDefaultFileLoadedLaterIsReported() throws {
        let fx = try makeStore("a = 1\n", extraFiles: [
            "config.ghostty": "theme = Dracula\nkeybind = global:cmd+shift+space=toggle_quick_terminal\n",
        ])
        defer { fx.cleanup() }
        let store = fx.store
        #expect(store.isOverridden("theme"))
        let finding = try #require(store.findings(for: "theme").first)
        #expect(finding.file?.hasSuffix("ghostty/config.ghostty") == true)
        #expect(finding.message.contains("loads after your config"))

        store.setGlobalKeybind(.toggleQuickTerminal, .set("cmd+f2"))
        #expect(store.leftActiveBindings.map(\.trigger) == ["cmd+shift+space"])
        #expect(store.leftActiveBindings.first?.file != nil)
    }

    @Test func includesAreScannedAndNoted() throws {
        let fx = try makeStore("config-file = ?extra.conf\n", extraFiles: [
            "extra.conf": "font-size = 20\nkeybind = global:alt+space=new_window\n",
        ])
        defer { fx.cleanup() }
        let store = fx.store
        #expect(store.isOverridden("font-size"))
        #expect(store.includeNote(for: "theme")?.isWarning == true)
        #expect(store.includeNote(for: "font-size")?.isWarning == false)
        store.setGlobalKeybind(.newWindow, .set("cmd+shift+n"))
        #expect(store.leftActiveBindings.map(\.trigger) == ["alt+space"])
    }

    @Test func flushesOnAppTermination() throws {
        let fx = try makeStore("a = 1\n")
        defer { fx.cleanup() }
        fx.store.set("theme", "Nord")
        NotificationCenter.default.post(name: Self.quitting, object: nil)
        #expect(!fx.store.hasPendingWrite)
        #expect(try fx.text().contains("theme = Nord"))
    }

    @Test func loadIsAsynchronousByDefault() async throws {
        let fx = try makeStore("a = 1\n")
        defer { fx.cleanup() }
        try "\(GhosttyConfigWriter.beginMarker)\ntheme = Nord\n\(GhosttyConfigWriter.endMarker)\n"
            .write(to: fx.url, atomically: true, encoding: .utf8)
        fx.store.load()
        for _ in 0 ..< 100 where fx.store.managed["theme"] == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fx.store.managed["theme"] == ["Nord"])
    }
}
