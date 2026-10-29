import Foundation
import Testing
@testable import Ghostty

/// Slimer: reading/writing the Ghostty config file. Every test uses its own temp
/// directory; nothing touches `~/.config/ghostty`.
struct GhosttyConfigFileTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("slimer-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func missingFileReadsEmptyAndIsCreated() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = GhosttyConfigFile(url: dir.appendingPathComponent("config"))
        #expect(try file.read() == "")
        try file.write("theme = Nord\n", backup: true)
        #expect(try file.read() == "theme = Nord\n")
        // Nothing to back up for a new file.
        #expect(!FileManager.default.fileExists(atPath: file.backupURL.path))
    }

    @Test func preservesPermissionsAndKeepsSingleBackup() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        try "font-size = 14\n".write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let file = GhosttyConfigFile(url: url)
        try file.write("font-size = 14\nA\n", backup: true)
        try file.write("font-size = 14\nB\n", backup: true)

        #expect(try mode(url) == 0o600)
        #expect(try String(contentsOf: file.backupURL, encoding: .utf8) == "font-size = 14\n")
        #expect(file.backupURL.lastPathComponent == "config.slimer-backup")
        #expect(try file.read() == "font-size = 14\nB\n")
        // No temp files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func writesThroughSymlink() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dotfiles = dir.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("ghostty.conf")
        try "a = 1\n".write(to: target, atomically: false, encoding: .utf8)
        let link = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let file = GhosttyConfigFile(url: link)
        try file.write("a = 2\n", backup: true)

        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(linkDest == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "a = 2\n")
        #expect(FileManager.default.fileExists(atPath: dotfiles.appendingPathComponent("ghostty.conf.slimer-backup").path))
    }

    @Test func refusesNonRegularFiles() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = GhosttyConfigFile(url: sub)
        #expect(throws: GhosttyConfigFile.FileError.self) { try file.read() }
        #expect(throws: GhosttyConfigFile.FileError.self) { try file.write("x\n", backup: false) }

        let fifo = dir.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: GhosttyConfigFile.FileError.self) { try GhosttyConfigFile(url: fifo).read() }
    }

    @Test func refusesNonUTF8() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: url)
        #expect(throws: GhosttyConfigFile.FileError.notUTF8(url.resolvingSymlinksInPath().path)) {
            try GhosttyConfigFile(url: url).read()
        }
    }

    @Test func endToEndKeepsUserLines() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        let original = "# my config\r\nfont-family = Iosevka\r\nkeybind = cmd+t=new_tab\r\n"
        try original.write(to: url, atomically: false, encoding: .utf8)

        let file = GhosttyConfigFile(url: url)
        let rendered = try GhosttyConfigWriter.render(text: try file.read(), entries: [
            .init("font-family", ["\"\"", "JetBrains Mono"]),
            .init("keybind", ["global:cmd+backquote=toggle_quick_terminal"]),
        ])
        try file.write(rendered, backup: true)

        let text = try file.read()
        #expect(text.hasPrefix(original))
        #expect(try GhosttyConfigWriter.managedEntries(in: text) == [
            .init("font-family", ["", "JetBrains Mono"]),
            .init("keybind", ["global:cmd+backquote=toggle_quick_terminal"]),
        ])
        #expect(try String(contentsOf: file.backupURL, encoding: .utf8) == original)
    }
}
