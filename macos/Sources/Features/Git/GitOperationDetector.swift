import Foundation

/// Detects an in-progress git operation from marker files inside the git directory.
///
/// This only checks for file presence; it never reads file contents, so hostile
/// content in `.git/` cannot influence the result. The priority order mirrors
/// git's own `__git_ps1` helper: a rebase (which can contain a merge state) wins
/// over a merge, then cherry-pick, revert, bisect.
enum GitOperationDetector {
    /// Marker paths, relative to the git directory, in priority order.
    static let markers: [(path: String, operation: GitRepoState.Operation)] = [
        ("rebase-merge", .rebase),
        ("rebase-apply", .rebase),
        ("MERGE_HEAD", .merge),
        ("CHERRY_PICK_HEAD", .cherryPick),
        ("REVERT_HEAD", .revert),
        ("BISECT_LOG", .bisect),
    ]

    /// - Parameter gitDir: The repository's git directory (`.git`, or the worktree
    ///   private directory for linked worktrees). Marker files live here, not in
    ///   the common directory.
    static func detect(gitDir: URL, fileManager: FileManager = .default) -> GitRepoState.Operation? {
        for marker in markers {
            let url = gitDir.appendingPathComponent(marker.path)
            if fileManager.fileExists(atPath: url.path) {
                return marker.operation
            }
        }
        return nil
    }
}
