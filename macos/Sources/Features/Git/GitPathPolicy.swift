import Foundation

/// Decides which directories the git service is allowed to inspect.
///
/// Running `git status` is cheap on a local checkout but can stall for seconds on a
/// network mount and is pointless at the filesystem root or inside system folders.
/// Those locations are skipped entirely and reported as "not a repository".
enum GitPathPolicy {
    enum SkipReason: Equatable, Sendable {
        /// The filesystem root `/`.
        case filesystemRoot
        /// `/System` or anything beneath it.
        case systemFolder
        /// The user's `~/Library` or anything beneath it.
        case userLibrary
        /// The directory lives on a non-local (network) volume.
        case networkVolume
        /// The directory does not exist or cannot be inspected.
        case unreadable
    }

    /// Returns why `directory` must be skipped, or `nil` when it may be inspected.
    ///
    /// This performs one `stat`-class lookup for the volume check and may block
    /// briefly on an unreachable mount, so call it from a background queue.
    static func skipReason(
        for directory: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SkipReason? {
        let path = directory.standardizedFileURL.path
        if let reason = pathSkipReason(path: path, homePath: home.standardizedFileURL.path) {
            return reason
        }

        // Resolve symlinks for the prefix checks too, so a link into /System or
        // ~/Library does not slip through.
        let resolved = directory.resolvingSymlinksInPath().path
        if resolved != path, let reason = pathSkipReason(path: resolved, homePath: home.resolvingSymlinksInPath().path) {
            return reason
        }

        guard let values = try? directory.resourceValues(forKeys: [.volumeIsLocalKey, .isDirectoryKey]) else {
            return .unreadable
        }
        guard values.isDirectory == true else { return .unreadable }
        if values.volumeIsLocal == false {
            return .networkVolume
        }
        return nil
    }

    /// Pure string checks, split out so they can be tested without a filesystem.
    static func pathSkipReason(path: String, homePath: String) -> SkipReason? {
        if path == "/" || path.isEmpty {
            return .filesystemRoot
        }
        if path == "/System" || path.hasPrefix("/System/") {
            return .systemFolder
        }
        let library = homePath.hasSuffix("/") ? homePath + "Library" : homePath + "/Library"
        if path == library || path.hasPrefix(library + "/") {
            return .userLibrary
        }
        return nil
    }
}
