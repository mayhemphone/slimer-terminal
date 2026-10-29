import Foundation

/// Pure rule evaluation. No I/O, no AppKit, so it is cheap to run on every debounced
/// pwd/title change and easy to unit test.
enum ThemeRuleMatcher {
    /// What we know about a surface when evaluating rules.
    struct Context: Equatable {
        /// The shell-reported working directory (OSC 7), if any.
        var pwd: String?
        /// The surface title as set by the shell/program.
        var title: String?
        /// Names of the local machine (short and fully qualified).
        var localHostnames: [String]

        init(pwd: String? = nil, title: String? = nil, localHostnames: [String] = []) {
            self.pwd = pwd
            self.title = title
            self.localHostnames = localHostnames
        }
    }

    /// Returns the winning rule, or `nil` if none match.
    ///
    /// Precedence: highest `priority`; then the most specific match (longest path prefix /
    /// longest value); then the earliest rule in the file.
    static func match(rules: [ThemeRule], context: Context, home: String) -> ThemeRule? {
        var best: (rule: ThemeRule, specificity: Int, index: Int)?
        for (index, rule) in rules.enumerated() {
            guard let specificity = specificity(of: rule, context: context, home: home) else { continue }
            if let current = best {
                if rule.priority > current.rule.priority ||
                    (rule.priority == current.rule.priority && specificity > current.specificity) {
                    best = (rule, specificity, index)
                }
            } else {
                best = (rule, specificity, index)
            }
        }
        return best?.rule
    }

    /// `nil` if the rule does not match; otherwise a specificity score (higher is more
    /// specific).
    static func specificity(of rule: ThemeRule, context: Context, home: String) -> Int? {
        switch rule.match {
        case .pathPrefix(let prefix):
            guard let pwd = context.pwd else { return nil }
            let path = standardizePath(pwd, home: home)
            let base = standardizePath(prefix, home: home)
            guard pathHasPrefix(path, prefix: base) else { return nil }
            return base.split(separator: "/").count

        case .hostname(let host):
            let wanted = host.lowercased()
            guard !wanted.isEmpty else { return nil }
            if context.localHostnames.contains(where: { $0.lowercased() == wanted }) {
                return wanted.count
            }
            if let title = context.title?.lowercased(), title.contains("@" + wanted) {
                return wanted.count
            }
            return nil

        case .command(let command):
            guard let title = context.title, titleNamesCommand(title, command: command) else { return nil }
            return command.count
        }
    }

    // MARK: Paths

    /// Lexical standardization: expands a leading `~`, collapses repeated slashes, drops
    /// `.` segments, resolves `..` segments without touching the filesystem, and removes
    /// trailing slashes. Symlinks are deliberately not resolved: matching is done on the
    /// path the shell reported, so a rule can never be tricked into following links.
    static func standardizePath(_ path: String, home: String) -> String {
        var expanded = path
        if expanded == "~" {
            expanded = home
        } else if expanded.hasPrefix("~/") {
            expanded = home + String(expanded.dropFirst())
        }

        var components: [Substring] = []
        for part in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(part)
            }
        }
        if expanded.hasPrefix("/") || path.hasPrefix("~") {
            return "/" + components.joined(separator: "/")
        }
        // A relative path can't match absolute prefixes; keep it relative so it never does.
        return components.joined(separator: "/")
    }

    /// Component-wise prefix test on standardized paths: `/a/b` is a prefix of `/a/b/c` but
    /// not of `/a/bc`.
    static func pathHasPrefix(_ path: String, prefix: String) -> Bool {
        guard path.hasPrefix("/"), prefix.hasPrefix("/") else { return false }
        if prefix == "/" { return true }
        if path == prefix { return true }
        return path.hasPrefix(prefix + "/")
    }

    // MARK: Commands

    /// True if `title` names `command`: equal, or the first whitespace-separated token
    /// equals it, or the first token's last path component equals it (`/usr/bin/vim`).
    /// Case-sensitive, like the shell.
    static func titleNamesCommand(_ title: String, command: String) -> Bool {
        let wanted = command.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed == wanted { return true }
        guard let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return false
        }
        if first == wanted { return true }
        if let last = first.split(separator: "/").last, last == wanted { return true }
        return false
    }

    // MARK: Host names

    /// The short and fully-qualified names of this machine, lowercased.
    static func localHostnames(from hostName: String) -> [String] {
        let full = hostName.lowercased()
        var names = [full]
        if let dot = full.firstIndex(of: "."), dot != full.startIndex {
            names.append(String(full[..<dot]))
        }
        // macOS appends ".local" to the computer name; strip it too.
        if full.hasSuffix(".local") {
            names.append(String(full.dropLast(".local".count)))
        }
        return Array(Set(names)).sorted()
    }
}
