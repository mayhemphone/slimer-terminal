import Foundation

/// Pure formatting helpers for the status bar chips. Nothing here touches a
/// surface or the filesystem, so all of it is unit tested directly.
enum StatusBarFormatting {
    /// Longest title we bother parsing for a `user@host` prefix. Titles come from
    /// the terminal (untrusted) and are only ever displayed.
    static let maxTitleLength = 256

    /// Abbreviate `path` for display: the home directory becomes `~`, and paths
    /// deeper than `maxComponents` below their root keep only the last
    /// `maxComponents` components behind an ellipsis.
    ///
    ///     /Users/me                  -> ~
    ///     /Users/me/Dev/slimer       -> ~/Dev/slimer
    ///     /Users/me/a/b/c/d          -> ~/…/b/c/d       (maxComponents 3)
    ///     /usr/local/share/man/man1  -> /…/share/man/man1
    static func abbreviate(path: String, home: String = NSHomeDirectory(), maxComponents: Int = 3) -> String {
        guard !path.isEmpty else { return path }
        var trimmedHome = home
        while trimmedHome.count > 1 && trimmedHome.hasSuffix("/") { trimmedHome.removeLast() }
        var trimmedPath = path
        while trimmedPath.count > 1 && trimmedPath.hasSuffix("/") { trimmedPath.removeLast() }

        let root: String
        let rest: String
        if !trimmedHome.isEmpty && trimmedHome != "/" && trimmedPath == trimmedHome {
            return "~"
        } else if !trimmedHome.isEmpty && trimmedHome != "/" && trimmedPath.hasPrefix(trimmedHome + "/") {
            root = "~/"
            rest = String(trimmedPath.dropFirst(trimmedHome.count + 1))
        } else if trimmedPath.hasPrefix("/") {
            root = "/"
            rest = String(trimmedPath.dropFirst())
        } else {
            root = ""
            rest = trimmedPath
        }

        let components = rest.split(separator: "/", omittingEmptySubsequences: true)
        guard maxComponents > 0, components.count > maxComponents else {
            return root + components.joined(separator: "/")
        }
        return root + "…/" + components.suffix(maxComponents).joined(separator: "/")
    }

    /// The `user@host` prefix of a terminal title, if the title looks like one.
    ///
    /// Accepts the shapes common shells set by default: `user@host`,
    /// `user@host: ~/dir`, `user@host:~/dir` and `user@host ~/dir`. Anything else
    /// (a running program's title, a path) returns `nil`.
    static func userHost(fromTitle title: String) -> String? {
        guard !title.isEmpty, title.count <= maxTitleLength else { return nil }
        let scalars = Array(title.unicodeScalars)
        guard let atIndex = scalars.firstIndex(of: "@"), atIndex > 0 else { return nil }

        let user = scalars[..<atIndex]
        guard user.count <= 64, user.allSatisfy(isUserScalar) else { return nil }

        var hostEnd = atIndex + 1
        while hostEnd < scalars.count, isHostScalar(scalars[hostEnd]) { hostEnd += 1 }
        let host = scalars[(atIndex + 1)..<hostEnd]
        guard !host.isEmpty, host.count <= 253 else { return nil }
        guard let first = host.first, let last = host.last, first != ".", first != "-", last != "-" else {
            return nil
        }

        // After the host: end of title, or a `:` / space separator.
        if hostEnd < scalars.count {
            let separator = scalars[hostEnd]
            guard separator == ":" || separator == " " else { return nil }
        }

        var result = String.UnicodeScalarView()
        result.append(contentsOf: user)
        result.append("@")
        result.append(contentsOf: host)
        return String(result)
    }

    /// Human duration for the last-command chip: `420ms`, `3.2s`, `4m 12s`, `1h 3m`.
    static func duration(nanoseconds: UInt64) -> String {
        let ms = nanoseconds / 1_000_000
        if ms < 1000 { return "\(ms)ms" }
        if ms < 10_000 {
            let tenths = ms / 100
            return "\(tenths / 10).\(tenths % 10)s"
        }
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    /// The badge text for an in-progress operation.
    static func operationBadge(_ operation: GitRepoState.Operation) -> String {
        switch operation {
        case .merge: return "MERGING"
        case .rebase: return "REBASING"
        case .cherryPick: return "CHERRY-PICKING"
        case .revert: return "REVERTING"
        case .bisect: return "BISECTING"
        }
    }

    private static func isUserScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", "-", ".": return true
        default: return false
        }
    }

    private static func isHostScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-", ".": return true
        default: return false
        }
    }
}
