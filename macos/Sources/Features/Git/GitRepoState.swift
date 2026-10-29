import Foundation

/// A snapshot of the git state of one repository.
///
/// This is the portable model shared by every status surface (status bar, popover,
/// command palette). It is a plain value: it carries no behaviour, never runs git,
/// and is safe to send across threads. See `docs/slimer/GIT.md` for the JSON shape
/// (the Windows host reimplements against the same encoding).
struct GitRepoState: Equatable, Codable, Sendable {
    /// An in-progress multi-step operation detected from marker files in `.git/`.
    enum Operation: String, Codable, Sendable, CaseIterable {
        case merge
        case rebase
        case cherryPick = "cherry-pick"
        case revert
        case bisect
    }

    /// Absolute path of the working tree root (`git rev-parse --show-toplevel`).
    var root: URL

    /// Current branch name, or `nil` when HEAD is detached.
    var branch: String?

    /// Short commit SHA when HEAD is detached, otherwise `nil`.
    var detachedHead: String?

    /// Upstream tracking ref (`origin/main`), or `nil` when none is configured.
    var upstream: String?

    /// Commits ahead of the upstream. Zero when no upstream exists.
    var ahead: Int

    /// Commits behind the upstream. Zero when no upstream exists.
    var behind: Int

    /// Tracked entries with a change in the index (`X != '.'`).
    var staged: Int

    /// Tracked entries with a change in the working tree (`Y != '.'`).
    var unstaged: Int

    /// Untracked, non-ignored entries (`?` records).
    var untracked: Int

    /// Unmerged entries (`u` records).
    var conflicted: Int

    /// Number of entries in the stash.
    var stashCount: Int

    /// In-progress operation, if any.
    var operation: Operation?

    /// When this snapshot was produced.
    var updatedAt: Date

    init(
        root: URL,
        branch: String? = nil,
        detachedHead: String? = nil,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        staged: Int = 0,
        unstaged: Int = 0,
        untracked: Int = 0,
        conflicted: Int = 0,
        stashCount: Int = 0,
        operation: Operation? = nil,
        updatedAt: Date = Date()
    ) {
        self.root = root
        self.branch = branch
        self.detachedHead = detachedHead
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.stashCount = stashCount
        self.operation = operation
        self.updatedAt = updatedAt
    }

    /// True when anything differs from HEAD (index, working tree, untracked or conflicts).
    var isDirty: Bool {
        staged > 0 || unstaged > 0 || untracked > 0 || conflicted > 0
    }

    /// True when HEAD is detached.
    var isDetached: Bool { branch == nil }

    /// A short label suitable for a chip: the branch name, or the short SHA when detached.
    var headLabel: String {
        branch ?? detachedHead ?? "HEAD"
    }

    // MARK: Codable

    // `root` is encoded as a plain filesystem path and `updatedAt` as Unix seconds so
    // the JSON shape is portable to hosts that do not understand `file://` URLs or
    // Foundation's reference-date encoding.

    private enum CodingKeys: String, CodingKey {
        case root
        case branch
        case detachedHead
        case upstream
        case ahead
        case behind
        case staged
        case unstaged
        case untracked
        case conflicted
        case stashCount
        case operation
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rootPath = try container.decode(String.self, forKey: .root)
        root = URL(fileURLWithPath: rootPath, isDirectory: true)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        detachedHead = try container.decodeIfPresent(String.self, forKey: .detachedHead)
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        ahead = try container.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try container.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        staged = try container.decodeIfPresent(Int.self, forKey: .staged) ?? 0
        unstaged = try container.decodeIfPresent(Int.self, forKey: .unstaged) ?? 0
        untracked = try container.decodeIfPresent(Int.self, forKey: .untracked) ?? 0
        conflicted = try container.decodeIfPresent(Int.self, forKey: .conflicted) ?? 0
        stashCount = try container.decodeIfPresent(Int.self, forKey: .stashCount) ?? 0
        operation = try container.decodeIfPresent(Operation.self, forKey: .operation)
        let seconds = try container.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        updatedAt = Date(timeIntervalSince1970: seconds)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root.path, forKey: .root)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encodeIfPresent(detachedHead, forKey: .detachedHead)
        try container.encodeIfPresent(upstream, forKey: .upstream)
        try container.encode(ahead, forKey: .ahead)
        try container.encode(behind, forKey: .behind)
        try container.encode(staged, forKey: .staged)
        try container.encode(unstaged, forKey: .unstaged)
        try container.encode(untracked, forKey: .untracked)
        try container.encode(conflicted, forKey: .conflicted)
        try container.encode(stashCount, forKey: .stashCount)
        try container.encodeIfPresent(operation, forKey: .operation)
        try container.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
    }
}
