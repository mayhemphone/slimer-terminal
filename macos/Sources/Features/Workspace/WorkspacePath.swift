import Foundation

/// Path helpers for the Workspace feature: `~` expansion, abbreviation, and
/// the location of `workspace.json` (XDG aware).
enum WorkspacePath {
    /// Expand a leading `~` (or `~/...`) to the home directory. Other paths
    /// are returned unchanged apart from trailing-slash normalization.
    static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: String
        if trimmed == "~" {
            result = home
        } else if trimmed.hasPrefix("~/") {
            result = home + trimmed.dropFirst(1)
        } else {
            result = trimmed
        }
        // Normalize trailing slashes (but keep "/" itself).
        while result.count > 1 && result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// Abbreviate the home directory prefix as `~`.
    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// A default display name for a path: its last component, or `~` for home.
    static func displayName(for path: String, home: String = NSHomeDirectory()) -> String {
        let expanded = expand(path, home: home)
        if expanded == home { return "~" }
        let last = (expanded as NSString).lastPathComponent
        return last.isEmpty ? expanded : last
    }

    /// `$XDG_CONFIG_HOME/slimer` when that variable is an absolute path,
    /// otherwise `~/.config/slimer`.
    static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("slimer", isDirectory: true)
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("slimer", isDirectory: true)
    }

    /// Whether the process is an XCTest host. The app's own store then uses
    /// a throwaway file so tests never seed or watch the real workspace.json.
    static func isRunningUnderXCTest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }

    /// The default `workspace.json` location. Under XCTest this is a
    /// per-process file in the temporary directory.
    static func defaultFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        if isRunningUnderXCTest(environment: environment) {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("slimer-xctest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("workspace.json", isDirectory: false)
        }
        return configDirectory(environment: environment, home: home)
            .appendingPathComponent("workspace.json", isDirectory: false)
    }

    /// Prefixes that are never recorded as recent directories: scratch
    /// locations, plus network and removable volumes (a `stat` there can hang).
    static let ignoredRecentPrefixes = [
        "/tmp", "/private/tmp", "/private/var/folders", "/var/folders",
        "/net", "/Network", "/Volumes",
    ]

    /// Longest path we accept from a working-directory report.
    static let maxRecordablePathLength = 1024

    /// Whether a working directory report (untrusted, shell-provided) is worth
    /// remembering. Pure string checks, cheap enough for the main thread; the
    /// existence check happens later off the main thread.
    static func isRecordable(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        guard path.utf8.count <= maxRecordablePathLength else { return false }
        guard WorkspaceShell.isSafeToInsert(path) else { return false }
        for prefix in ignoredRecentPrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return false
        }
        return true
    }
}
