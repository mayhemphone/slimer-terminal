import Foundation

/// A github.com repository identified from a git remote URL.
///
/// Remote URLs come from the repository's own config, which may be hostile, so
/// parsing is strict: only `https://github.com/...`, `ssh://git@github.com/...`
/// and the scp-like `git@github.com:...` forms are accepted, and owner and repo
/// must be plain GitHub names. Every URL built from it is https on github.com.
struct GitHubRemote: Equatable, Sendable {
    let owner: String
    let repo: String

    /// Parse a remote URL as printed by `git remote get-url origin`.
    init?(remoteURL raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1024 else { return nil }

        let path: Substring
        if let range = text.range(of: "://") {
            let scheme = text[..<range.lowerBound].lowercased()
            var rest = text[range.upperBound...]
            // Authority ends at the first `/`.
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = rest[..<slash]
            rest = rest[rest.index(after: slash)...]
            switch scheme {
            case "https":
                // Allow `user@` / `user:token@` userinfo, which git keeps in the URL.
                if let at = authority.lastIndex(of: "@") {
                    authority = authority[authority.index(after: at)...]
                }
            case "ssh":
                guard let at = authority.lastIndex(of: "@"), authority[..<at] == "git" else { return nil }
                authority = authority[authority.index(after: at)...]
            default:
                return nil
            }
            // An explicit default port is fine; anything else is not github.com.
            let host = authority.lowercased()
            let allowedHosts: Set<String> = scheme == "https"
                ? ["github.com", "github.com:443", "www.github.com"]
                : ["github.com", "github.com:22"]
            guard allowedHosts.contains(host) else { return nil }
            path = rest
        } else {
            // scp-like syntax: git@github.com:owner/repo.git
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let authority = text[..<colon]
            guard authority.lowercased() == "git@github.com" else { return nil }
            path = text[text.index(after: colon)...]
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: false)
        // Tolerate one trailing slash.
        if components.count == 3, components[2].isEmpty { components.removeLast() }
        guard components.count == 2 else { return nil }
        let owner = String(components[0])
        var repo = String(components[1])
        if repo.lowercased().hasSuffix(".git") { repo.removeLast(4) }
        guard Self.isValidOwner(owner), Self.isValidRepo(repo) else { return nil }
        self.owner = owner
        self.repo = repo
    }

    init?(owner: String, repo: String) {
        guard Self.isValidOwner(owner), Self.isValidRepo(repo) else { return nil }
        self.owner = owner
        self.repo = repo
    }

    /// `https://github.com/<owner>/<repo>`
    var repositoryURL: URL? {
        Self.validated(URL(string: "https://github.com/\(owner)/\(repo)"))
    }

    /// `https://github.com/<owner>/<repo>/pull/new/<branch>`, with the branch
    /// percent-encoded (slashes kept as path separators, which GitHub expects).
    func newPullRequestURL(branch: String) -> URL? {
        guard GitShellQuoting.isSafe(branch), let encoded = Self.encodeBranch(branch) else { return nil }
        return Self.validated(URL(string: "https://github.com/\(owner)/\(repo)/pull/new/\(encoded)"))
    }

    /// Percent-encode a branch name for a URL path. Only ASCII unreserved
    /// characters and `/` are left as-is. Returns `nil` for names with empty or
    /// dot-only segments, which would change the path's meaning.
    static func encodeBranch(_ branch: String) -> String? {
        let segments = branch.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return nil }
        for segment in segments where segment.isEmpty || segment == "." || segment == ".." {
            return nil
        }
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        return branch.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private static func validated(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }

    /// GitHub user and org names: alphanumerics and single hyphens, max 39.
    private static func isValidOwner(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 39, !name.hasPrefix("-") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-": return true
            default: return false
            }
        }
    }

    /// GitHub repository names: alphanumerics, `-`, `_`, `.`, max 100, not `.`/`..`.
    private static func isValidRepo(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 100, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".": return true
            default: return false
            }
        }
    }
}

extension GitStatusService {
    /// The github.com repository behind `origin` for the repository at `root`, or
    /// `nil` when there is no origin or it is not on github.com.
    ///
    /// Read-only: one `git remote get-url origin` through the service's restricted
    /// runner, off the main thread, with the usual 2 s timeout.
    func gitHubRemote(root: URL) async -> GitHubRemote? {
        guard let runner else { return nil }
        let output: GitProcessRunner.Output = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runner.run(
                    ["remote", "get-url", "origin"],
                    in: root,
                    timeout: Self.commandTimeout
                ))
            }
        }
        guard output.succeeded else { return nil }
        let firstLine = output.stdoutText.split(separator: "\n").first.map(String.init) ?? ""
        return GitHubRemote(remoteURL: firstLine)
    }
}
