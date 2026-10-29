import Foundation

/// Turns a named Ghostty theme into a list of color-only `key=value` args.
///
/// Security model: a theme file is a full Ghostty config, so it could set keybinds,
/// clipboard access, commands, and so on. We never hand a theme name or path to
/// libghostty. Instead we:
///
/// 1. accept only plain names (no `/`, `\`, `..`, leading `~` or `.`, or control characters),
///    so absolute paths and traversal are impossible;
/// 2. look the name up in the user's Ghostty themes dir, then the bundled one;
/// 3. open it non-blocking and require a regular file under a size cap, so a FIFO or device
///    can never hang the main thread;
/// 4. parse it ourselves and keep only color keys with strict `#RRGGBB` values.
///
/// The result is passed through `ghostty_config_load_arg`, which also allowlists keys.
enum GhosttyThemeResolver {
    static let colorKeys: Set<String> = [
        "background", "foreground", "cursor-color", "cursor-text",
        "selection-background", "selection-foreground",
    ]

    /// Only the 16 ANSI palette entries are taken from theme files.
    static let paletteRange = 0...15

    static let maxFileBytes = 256 * 1024

    // MARK: Names

    /// A plain theme file name. Rejects anything that could act as a path.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 128 else { return false }
        guard !name.hasPrefix("~"), !name.hasPrefix(".") else { return false }
        guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// Picks the name to use from `X` or `light:X,dark:Y` (Ghostty's syntax).
    /// Returns nil if the value is malformed.
    static func selectName(_ value: String, dark: Bool) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("light:") || trimmed.hasPrefix("dark:") else { return trimmed }
        var light: String?
        var darkName: String?
        for part in trimmed.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("light:") {
                light = String(p.dropFirst("light:".count)).trimmingCharacters(in: .whitespaces)
            } else if p.hasPrefix("dark:") {
                darkName = String(p.dropFirst("dark:".count)).trimmingCharacters(in: .whitespaces)
            } else {
                return nil
            }
        }
        return dark ? (darkName ?? light) : (light ?? darkName)
    }

    // MARK: Lookup

    /// Directories searched in order: the user's Ghostty themes dir, then the app bundle's.
    static func searchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> [URL] {
        var dirs: [URL] = []
        let configBase: URL
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            configBase = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            configBase = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        dirs.append(configBase.appendingPathComponent("ghostty/themes", isDirectory: true))
        if let resources = bundle.resourceURL {
            dirs.append(resources.appendingPathComponent("ghostty/themes", isDirectory: true))
        }
        return dirs
    }

    /// Color args for `value` (a name or `light:…,dark:…` pair), or nil if it can't be
    /// resolved safely. Nil is logged by the caller.
    static func colorArgs(for value: String, dark: Bool, directories: [URL]) -> [String]? {
        guard let name = selectName(value, dark: dark), isSafeName(name) else { return nil }
        for dir in directories {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            // Defense in depth: the joined path must stay directly inside `dir`.
            guard url.deletingLastPathComponent().standardizedFileURL.path
                    == dir.standardizedFileURL.path else { continue }
            if let text = readRegularFile(url) {
                return parseColorArgs(text)
            }
        }
        return nil
    }

    // MARK: File access

    /// Reads a regular file of at most `maxBytes` without blocking on FIFOs or devices.
    static func readRegularFile(_ url: URL, maxBytes: Int = maxFileBytes) -> String? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard info.st_size >= 0, info.st_size <= maxBytes else { return nil }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maxBytes {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { return nil }
            if n == 0 { break }
            data.append(buffer, count: n)
        }
        guard data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Parsing

    /// Extracts color settings from Ghostty config text. Everything that isn't a color key
    /// with a valid hex value (or an in-range palette entry) is ignored.
    static func parseColorArgs(_ text: String) -> [String] {
        var args: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))

            if colorKeys.contains(key) {
                if let hex = normalizeHex(value) { args.append("\(key)=\(hex)") }
            } else if key == "palette" {
                guard let peq = value.firstIndex(of: "=") else { continue }
                let indexText = value[..<peq].trimmingCharacters(in: .whitespaces)
                let colorText = value[value.index(after: peq)...].trimmingCharacters(in: .whitespaces)
                guard let index = Int(indexText), paletteRange.contains(index),
                      let hex = normalizeHex(colorText) else { continue }
                args.append("palette=\(index)=\(hex)")
            }
        }
        return args
    }

    /// `#RRGGBB` or bare `RRGGBB` → `#RRGGBB`; anything else → nil.
    static func normalizeHex(_ value: String) -> String? {
        let candidate = value.hasPrefix("#") ? value : "#" + value
        return SurfaceTheme.isValidHex(candidate) ? candidate : nil
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
