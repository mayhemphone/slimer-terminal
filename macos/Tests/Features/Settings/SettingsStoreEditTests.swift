import Foundation
import SwiftUI
import Testing
@testable import Ghostty

/// Slimer: the small editing APIs Settings added to ThemeStore and WorkspaceStore.
struct SettingsStoreEditTests {
    private func tempURL(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test func themeRulesUpdateAndMove() throws {
        let url = try tempURL("themes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ThemeStore(fileURL: url, watch: false)
        let theme = try #require(store.themes.first)
        let a = ThemeRule(match: .pathPrefix("~/a"), themeId: theme.id)
        let b = ThemeRule(match: .hostname("b"), themeId: theme.id)
        let c = ThemeRule(match: .command("c"), themeId: theme.id)
        [a, b, c].forEach { store.add(rule: $0) }

        store.moveRules(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.rules.map(\.id) == [c.id, a.id, b.id])
        store.moveRules(fromOffsets: IndexSet([0, 1]), toOffset: 3)
        #expect(store.rules.map(\.id) == [b.id, c.id, a.id])
        store.moveRules(fromOffsets: IndexSet(integer: 9), toOffset: 0)   // ignored
        #expect(store.rules.count == 3)

        var changed = b
        changed.priority = 5
        changed.match = .hostname("prod")
        store.update(rule: changed)
        let reopened = ThemeStore(fileURL: url, watch: false)
        #expect(reopened.rules.first == changed)
        #expect(reopened.acceptsEdits)
    }

    @Test func lossyThemesFileRejectsEdits() throws {
        let url = try tempURL("themes.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try #"{"version": 99, "themes": [], "rules": []}"#.write(to: url, atomically: true, encoding: .utf8)
        let store = ThemeStore(fileURL: url, watch: false)
        #expect(store.persistence == .lossy)
        #expect(!store.acceptsEdits)
    }

    @Test func workspaceEditPersistsAndKeepsUsage() throws {
        let url = try tempURL("workspace.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let local = url.deletingLastPathComponent().appendingPathComponent("local", isDirectory: true)
        let store = WorkspaceStore(fileURL: url, localDirectory: local, watch: false)
        #expect(store.acceptsEdits)
        let location = WorkspaceLocation(name: "Src", path: "~/src", shortcut: "cmd+shift+9")
        store.edit { $0.locations.append(location) }
        store.edit { $0.moveVisibleLocations(fromOffsets: IndexSet(integer: $0.visibleLocations.count - 1), toOffset: 0) }
        store.commitVisit(NSHomeDirectory())
        store.clearRecent()

        let reopened = WorkspaceStore(fileURL: url, localDirectory: local, watch: false)
        #expect(reopened.document.locations.first?.id == location.id)
        #expect(reopened.document.locations.first?.shortcut == "cmd+shift+9")
        #expect(reopened.recent.recent.isEmpty)
    }

    @Test func invalidWorkspaceFileRejectsEdits() throws {
        let url = try tempURL("workspace.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try "{ not json".write(to: url, atomically: true, encoding: .utf8)
        let store = WorkspaceStore(fileURL: url, watch: false)
        #expect(!store.acceptsEdits)
        store.edit { $0.locations.removeAll() }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")
    }
}
