import Foundation

/// Reads and writes the user's Ghostty config file for Settings.
///
/// - The path is the one "Open Config" uses (see ``SettingsConfigStore``), so Settings edits
///   the same file the user does.
/// - A symlinked config (dotfiles) is written through to its target; the link stays.
/// - Writes are atomic: a temp file in the target's directory, `fsync`, then `rename(2)`.
///   The original file's permissions are kept.
/// - Before the first write that adds Slimer's block, a copy is kept next to the file as
///   `<name>.slimer-backup`. It is never overwritten.
/// - Only regular, UTF-8 files up to 1 MiB are read or written.
struct GhosttyConfigFile {
    static let maxBytes = 1024 * 1024
    static let backupSuffix = ".slimer-backup"

    enum FileError: Error, Equatable, CustomStringConvertible {
        case notRegularFile(String)
        case tooLarge(String)
        case notUTF8(String)
        case readFailed(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case .notRegularFile(let path): return "\(path) is not a regular file."
            case .tooLarge(let path): return "\(path) is larger than 1 MiB."
            case .notUTF8(let path): return "\(path) is not UTF-8 text."
            case .readFailed(let reason): return "Couldn't read the config: \(reason)"
            case .writeFailed(let reason): return "Couldn't write the config: \(reason)"
            }
        }
    }

    /// The path as configured (may be a symlink).
    let url: URL

    /// Where bytes are actually stored: `url` with every symlink resolved.
    var targetURL: URL { url.resolvingSymlinksInPath() }

    var backupURL: URL {
        let target = targetURL
        return target.deletingLastPathComponent()
            .appendingPathComponent(target.lastPathComponent + Self.backupSuffix)
    }

    // MARK: Reading

    /// The file's text. A missing file reads as empty.
    func read() throws -> String {
        let path = targetURL.path
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno == ENOENT { return "" }
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
        guard let text = String(data: data, encoding: .utf8) else { throw FileError.notUTF8(path) }
        return text
    }

    // MARK: Writing

    /// Atomically replaces the file's contents with `text`.
    ///
    /// - Parameter backup: when true and no backup exists yet, the current contents are
    ///   copied to ``backupURL`` first.
    func write(_ text: String, backup: Bool) throws {
        let fm = FileManager.default
        let target = targetURL
        let directory = target.deletingLastPathComponent()

        var mode: mode_t = 0o644
        var st = stat()
        let exists = lstat(target.path, &st) == 0
        if exists {
            guard (st.st_mode & S_IFMT) == S_IFREG else { throw FileError.notRegularFile(target.path) }
            mode = st.st_mode & 0o7777
        } else {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if backup, exists, !fm.fileExists(atPath: backupURL.path) {
            do {
                try fm.copyItem(at: target, to: backupURL)
            } catch {
                throw FileError.writeFailed("could not create \(backupURL.lastPathComponent): \(error.localizedDescription)")
            }
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
        // umask may have narrowed the create mode; restore the original exactly.
        ok = ok && fchmod(fd, mode) == 0 && fsync(fd) == 0
        let reason = ok ? "" : String(cString: strerror(errno))
        close(fd)
        guard ok else {
            unlink(temp.path)
            throw FileError.writeFailed(reason)
        }
        if rename(temp.path, target.path) != 0 {
            let reason = String(cString: strerror(errno))
            unlink(temp.path)
            throw FileError.writeFailed(reason)
        }
    }
}
