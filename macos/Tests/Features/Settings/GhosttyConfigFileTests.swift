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
        let snapshot = try file.readSnapshot()
        #expect(snapshot.text == "")
        #expect(snapshot.stamp == nil)
        try file.write("theme = Nord\n", expected: nil, backup: true)
        #expect(try file.read() == "theme = Nord\n")
        // Nothing to back up for a new file.
        #expect(file.backups().isEmpty)
    }

    @Test func preservesPermissionsAndXattrs() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        try "font-size = 14\n".write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let value = Array("slimer".utf8)
        #expect(setxattr(url.path, "top.mayhem.test", value, value.count, 0, 0) == 0)

        let file = GhosttyConfigFile(url: url)
        let snapshot = try file.readSnapshot()
        try file.write("font-size = 14\nA\n", expected: snapshot.stamp, backup: false)

        #expect(try mode(url) == 0o640)
        var buffer = [UInt8](repeating: 0, count: 16)
        let size = getxattr(url.path, "top.mayhem.test", &buffer, buffer.count, 0, 0)
        #expect(size == value.count)
        #expect(Array(buffer.prefix(max(size, 0))) == value)
        // No temp files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func timestampedBackupsKeepTheOldestAndNewestTwo() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        try "v0\n".write(to: url, atomically: false, encoding: .utf8)
        let file = GhosttyConfigFile(url: url)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 1...5 {
            try file.write("v\(n)\n", expected: nil, checkUnchanged: false, backup: true,
                           now: base.addingTimeInterval(Double(n)))
        }
        let backups = file.backups()
        #expect(backups.count == 3)
        #expect(backups.allSatisfy { $0.lastPathComponent.hasPrefix("config.slimer-backup-") })
        // v0 is the config before Slimer's first write: it is never rotated out.
        #expect(try backups.map { try String(contentsOf: $0, encoding: .utf8) } == ["v0\n", "v3\n", "v4\n"])
        #expect(file.backupURL(at: base).lastPathComponent.count == "config.slimer-backup-YYYYMMDD-HHMMSS".count)
    }

    @Test func pruningPolicy() {
        let urls = (0..<6).map { URL(fileURLWithPath: "/tmp/config.slimer-backup-2026010\($0)-000000") }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let inOrder = urls.enumerated().map { (url: $0.element, created: Optional(base.addingTimeInterval(Double($0.offset)))) }
        #expect(GhosttyConfigFile.backupsToPrune(Array(inOrder.prefix(3))).isEmpty)
        #expect(GhosttyConfigFile.backupsToPrune(Array(inOrder.prefix(4))) == [urls[1]])
        #expect(GhosttyConfigFile.backupsToPrune(inOrder) == Array(urls[1...3]))

        // After a time zone move the original (created first) can carry a later name; it is
        // still kept, along with the oldest name and the newest two.
        var moved = inOrder
        moved[2].created = base.addingTimeInterval(-3600)
        #expect(GhosttyConfigFile.backupsToPrune(moved) == [urls[1], urls[3]])

        // Unknown creation dates never cause extra pruning.
        let undated = urls.map { (url: $0, created: Date?.none) }
        #expect(GhosttyConfigFile.backupsToPrune(undated) == Array(urls[1...3]))
    }

    @Test func backupNamesAreUTCAndOnlyExactNamesArePruned() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        try "v0\n".write(to: url, atomically: false, encoding: .utf8)
        let file = GhosttyConfigFile(url: url)
        #expect(file.backupURL(at: Date(timeIntervalSince1970: 0)).lastPathComponent
                == "config.slimer-backup-19700101-000000")

        // The user's own files that merely share the prefix are never touched.
        let foreign = ["config.slimer-backup-keep", "config.slimer-backup-20260101-000000.txt",
                       "config.slimer-backup-2026010-0000000", "other.slimer-backup-20200101-000000"]
        for name in foreign {
            try "mine\n".write(to: dir.appendingPathComponent(name), atomically: false, encoding: .utf8)
        }
        #expect(file.backups().isEmpty)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for n in 1...6 {
            try file.write("v\(n)\n", expected: nil, checkUnchanged: false, backup: true,
                           now: base.addingTimeInterval(Double(n)))
        }
        #expect(file.backups().count == 3)
        for name in foreign {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
        #expect(GhosttyConfigFile.isBackupName("config.slimer-backup-20260101-123456", for: "config"))
        #expect(!GhosttyConfigFile.isBackupName("config.slimer-backup-2026010a-123456", for: "config"))
        #expect(!GhosttyConfigFile.isBackupName("config.slimer-backup-20260101_123456", for: "config"))
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
        let snapshot = try file.readSnapshot()
        try file.write("a = 2\n", expected: snapshot.stamp, backup: true)

        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(linkDest == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "a = 2\n")
        #expect(file.backups().first?.deletingLastPathComponent().lastPathComponent == "dotfiles")
    }

    @Test func danglingSymlinkIsAnError() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("missing/conf"))
        let file = GhosttyConfigFile(url: link)
        #expect(throws: GhosttyConfigFile.FileError.danglingSymlink(link.path)) { try file.read() }
        #expect(throws: GhosttyConfigFile.FileError.danglingSymlink(link.path)) {
            try file.write("x = 1\n", expected: nil, backup: false)
        }
        // The link is still a link.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test func refusesReadOnlyFile() throws {
        let dir = try makeDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("config").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("config")
        try "a = 1\n".write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let file = GhosttyConfigFile(url: url)
        let snapshot = try file.readSnapshot()
        #expect(throws: GhosttyConfigFile.FileError.readOnly(file.targetURL.path)) {
            try file.write("a = 2\n", expected: snapshot.stamp, backup: true)
        }
        #expect(try file.read() == "a = 1\n")
    }

    @Test func abortsWhenFileChangedSinceRead() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        try "a = 1\n".write(to: url, atomically: false, encoding: .utf8)
        let file = GhosttyConfigFile(url: url)
        let snapshot = try file.readSnapshot()
        // An editor saves (rename over the file) after our read.
        try "a = 1\nb = 2\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(throws: GhosttyConfigFile.FileError.changedOnDisk(file.targetURL.path)) {
            try file.write("a = 1\nX\n", expected: snapshot.stamp, backup: false)
        }
        #expect(try file.read() == "a = 1\nb = 2\n")
        // A file that appeared after a "missing" read is also a change.
        let fresh = GhosttyConfigFile(url: dir.appendingPathComponent("new"))
        try "y\n".write(to: fresh.url, atomically: false, encoding: .utf8)
        #expect(throws: GhosttyConfigFile.FileError.self) { try fresh.write("z\n", expected: nil, backup: false) }
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

    @Test func keepsUTF8BOMOnDisk() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        try Data([0xEF, 0xBB, 0xBF] + Array("a = 1\n".utf8)).write(to: url)
        let file = GhosttyConfigFile(url: url)
        let snapshot = try file.readSnapshot()
        let rendered = try GhosttyConfigWriter.render(text: snapshot.text, entries: [.init("theme", ["Nord"])])
        try file.write(rendered, expected: snapshot.stamp, backup: false)
        let data = try Data(contentsOf: url)
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF, UInt8(ascii: "a")]))
        #expect(data.filter { $0 == 0xEF }.count == 1)
    }

    @Test func endToEndKeepsUserLines() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        let original = "# my config\r\nfont-family = Iosevka\r\nkeybind = cmd+t=new_tab\r\n"
        try original.write(to: url, atomically: false, encoding: .utf8)

        let file = GhosttyConfigFile(url: url)
        let snapshot = try file.readSnapshot()
        let rendered = try GhosttyConfigWriter.render(text: snapshot.text, entries: [
            .init("font-family", ["\"\"", "JetBrains Mono"]),
            .init("keybind", ["global:cmd+backquote=toggle_quick_terminal"]),
        ])
        try file.write(rendered, expected: snapshot.stamp, backup: true)

        let text = try file.read()
        #expect(text.hasPrefix(original))
        #expect(try GhosttyConfigWriter.managedEntries(in: text) == [
            .init("font-family", ["", "JetBrains Mono"]),
            .init("keybind", ["global:cmd+backquote=toggle_quick_terminal"]),
        ])
        #expect(try file.backups().map { try String(contentsOf: $0, encoding: .utf8) } == [original])
    }
}
