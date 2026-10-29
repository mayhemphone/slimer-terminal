import Foundation

/// Reads and writes the user's Ghostty config file for Settings.
///
/// - The path is the one "Open Config" uses (see ``SettingsConfigStore``), so Settings edits
///   the same file the user does.
/// - A symlinked config (dotfiles) is written through to its target; the link stays. A
///   dangling symlink is an error, never silently replaced.
/// - Writes are atomic: a temp file in the target's directory with the original mode,
///   extended attributes and ACL, `F_FULLFSYNC`, then `rename(2)`, then the directory is
///   synced. Right before the rename the target is re-checked; if it changed since it was
///   read (an editor saving at the same moment), the write is abandoned.
/// - A read-only file (or directory) is refused rather than replaced.
/// - Each write that newly adds Slimer's block first keeps a timestamped copy next to the
///   file (`<name>.slimer-backup-YYYYMMDD-HHMMSS`); the oldest (the config before Slimer
///   first edited it) and the newest two are kept.
/// - Only regular, UTF-8 files up to 1 MiB are read or written.
struct GhosttyConfigFile {
    static let maxBytes = 1024 * 1024
    static let backupPrefix = ".slimer-backup-"
    static let backupsKept = 3

    /// Identity and version of the file as last read, to notice concurrent saves.
    struct Stamp: Equatable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var mtimeSeconds: Int
        var mtimeNanoseconds: Int

        init(_ st: stat) {
            device = Int64(st.st_dev)
            inode = UInt64(st.st_ino)
            size = Int64(st.st_size)
            mtimeSeconds = Int(st.st_mtimespec.tv_sec)
            mtimeNanoseconds = Int(st.st_mtimespec.tv_nsec)
        }
    }

    struct Snapshot: Equatable {
        var text: String
        /// nil when the file doesn't exist.
        var stamp: Stamp?
    }

    enum FileError: Error, Equatable, CustomStringConvertible {
        case notRegularFile(String)
        case tooLarge(String)
        case notUTF8(String)
        case danglingSymlink(String)
        case readOnly(String)
        case changedOnDisk(String)
        case vanished(String)
        case readFailed(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case .notRegularFile(let path): return "\(path) is not a regular file."
            case .tooLarge(let path): return "\(path) is larger than 1 MiB."
            case .notUTF8(let path): return "\(path) is not UTF-8 text."
            case .danglingSymlink(let path):
                return "\(path) is a symlink to a file that doesn't exist. Fix the link (or create its target); Settings won't replace it."
            case .readOnly(let path):
                return "\(path) isn't writable. Settings won't change a read-only config."
            case .changedOnDisk(let path):
                return "\(path) changed while Settings was saving (an editor saving it?). Nothing was written; try again."
            case .vanished(let path):
                return "\(path) disappeared since Settings read it (an editor in the middle of saving?). Nothing was written; reopen Settings to retry."
            case .readFailed(let reason): return "Couldn't read the config: \(reason)"
            case .writeFailed(let reason): return "Couldn't write the config: \(reason)"
            }
        }
    }

    /// The path as configured (may be a symlink).
    let url: URL

    /// Where bytes are actually stored: `url` with every symlink resolved.
    var targetURL: URL { url.resolvingSymlinksInPath() }

    // MARK: Reading

    /// The file's text. A missing file reads as empty.
    func read() throws -> String {
        try readSnapshot().text
    }

    /// The file's text and identity. A missing file reads as empty with no stamp.
    func readSnapshot() throws -> Snapshot {
        try checkNotDangling()
        let path = targetURL.path
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno == ENOENT { return Snapshot(text: "", stamp: nil) }
            throw FileError.readFailed(String(cString: strerror(errno)))
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw FileError.notRegularFile(path) }
        guard st.st_size <= Self.maxBytes else { throw FileError.tooLarge(path) }

        // O_NONBLOCK so a file swapped for a FIFO between lstat and open can't hang us.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FileError.readFailed(String(cString: strerror(errno))) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var fdStat = stat()
        guard fstat(fd, &fdStat) == 0, (fdStat.st_mode & S_IFMT) == S_IFREG else {
            throw FileError.notRegularFile(path)
        }
        let data: Data
        do {
            data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
        } catch {
            throw FileError.readFailed(error.localizedDescription)
        }
        guard data.count <= Self.maxBytes else { throw FileError.tooLarge(path) }
        guard var text = String(data: data, encoding: .utf8) else { throw FileError.notUTF8(path) }
        // Keep a UTF-8 BOM visible to the writer (so it is written back) even if decoding
        // dropped it.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) && !text.hasPrefix("\u{FEFF}") {
            text = "\u{FEFF}" + text
        }
        return Snapshot(text: text, stamp: Stamp(fdStat))
    }

    /// A symlink whose target is missing would otherwise be "resolved" to itself and
    /// replaced by a regular file, silently breaking the user's dotfiles link.
    private func checkNotDangling() throws {
        var linkStat = stat()
        guard lstat(url.path, &linkStat) == 0, (linkStat.st_mode & S_IFMT) == S_IFLNK else { return }
        var targetStat = stat()
        if stat(url.path, &targetStat) != 0 && errno == ENOENT {
            throw FileError.danglingSymlink(url.path)
        }
    }

    // MARK: Writing

    /// Atomically replaces the file's contents with `text`, without checking for
    /// concurrent changes. Prefer ``write(_:expected:backup:now:)``.
    func write(_ text: String, backup: Bool) throws {
        try write(text, expected: nil, checkUnchanged: false, backup: backup)
    }

    /// Atomically replaces the file's contents with `text`.
    ///
    /// - Parameters:
    ///   - expected: the stamp from the read this text was rendered from (nil = the file
    ///     didn't exist). If the file no longer matches right before the rename, throws
    ///     ``FileError/changedOnDisk(_:)`` and leaves it alone.
    ///   - backup: keep a timestamped copy of the current contents first.
    func write(
        _ text: String,
        expected: Stamp?,
        checkUnchanged: Bool = true,
        backup: Bool,
        now: Date = Date()
    ) throws {
        try checkNotDangling()
        let fm = FileManager.default
        let target = targetURL
        let directory = target.deletingLastPathComponent()

        var mode: mode_t = 0o644
        var st = stat()
        let exists = lstat(target.path, &st) == 0
        if exists {
            guard (st.st_mode & S_IFMT) == S_IFREG else { throw FileError.notRegularFile(target.path) }
            guard access(target.path, W_OK) == 0 else { throw FileError.readOnly(target.path) }
            mode = st.st_mode & 0o7777
        } else {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard access(directory.path, W_OK) == 0 else { throw FileError.readOnly(directory.path) }
        if checkUnchanged {
            try verifyUnchanged(target: target, expected: expected)
        }

        if backup, exists {
            try makeBackup(of: target, now: now)
        }

        let temp = directory.appendingPathComponent(".\(target.lastPathComponent).slimer-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw FileError.writeFailed(String(cString: strerror(errno))) }

        let data = Data(text.utf8)
        var ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
        if ok && exists {
            // Keep extended attributes (e.g. Finder tags) and the ACL of the original. Best
            // effort: some filesystems support neither, and that shouldn't block the save.
            _ = copyfile(target.path, temp.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
        }
        // umask may have narrowed the create mode; restore the original exactly. Then make
        // the bytes durable (F_FULLFSYNC flushes the drive cache; fall back to fsync).
        ok = ok && fchmod(fd, mode) == 0 && (fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0)
        let reason = ok ? "" : String(cString: strerror(errno))
        close(fd)
        guard ok else {
            unlink(temp.path)
            throw FileError.writeFailed(reason)
        }

        if checkUnchanged {
            do {
                try verifyUnchanged(target: target, expected: expected)
            } catch {
                unlink(temp.path)
                throw error
            }
        }
        if rename(temp.path, target.path) != 0 {
            let reason = String(cString: strerror(errno))
            unlink(temp.path)
            throw FileError.writeFailed(reason)
        }
        // Make the rename itself durable.
        let dirFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        if dirFD >= 0 {
            _ = fsync(dirFD)
            close(dirFD)
        }
    }

    private func verifyUnchanged(target: URL, expected: Stamp?) throws {
        var st = stat()
        let current: Stamp? = lstat(target.path, &st) == 0 ? Stamp(st) : nil
        guard current == expected else { throw FileError.changedOnDisk(target.path) }
    }

    // MARK: Backups

    /// `<name>.slimer-backup-YYYYMMDD-HHMMSS` next to the target.
    func backupURL(at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = targetURL
        return target.deletingLastPathComponent()
            .appendingPathComponent(target.lastPathComponent + Self.backupPrefix + formatter.string(from: date))
    }

    /// Existing backups, oldest first.
    func backups() -> [URL] {
        let target = targetURL
        let dir = target.deletingLastPathComponent()
        let prefix = target.lastPathComponent + Self.backupPrefix
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().map { dir.appendingPathComponent($0) }
    }

    private func makeBackup(of target: URL, now: Date) throws {
        let fm = FileManager.default
        let backup = backupURL(at: now)
        if !fm.fileExists(atPath: backup.path) {
            do {
                try fm.copyItem(at: target, to: backup)
            } catch {
                throw FileError.writeFailed("could not create \(backup.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for old in Self.backupsToPrune(backups()) {
            try? fm.removeItem(at: old)
        }
    }

    /// Which of `backups` (oldest first) to delete: all but the oldest and the newest
    /// ``backupsKept`` − 1. The oldest is the config as it was before Slimer first touched
    /// it, so no amount of later backups can rotate it out.
    static func backupsToPrune(_ backups: [URL]) -> [URL] {
        guard backups.count > backupsKept else { return [] }
        return Array(backups.dropFirst().dropLast(backupsKept - 1))
    }
}
