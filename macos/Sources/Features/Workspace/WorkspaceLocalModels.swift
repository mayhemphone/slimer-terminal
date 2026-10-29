import Foundation

// Slimer Workspace: per-machine data that is NOT synced with workspace.json:
// recent directories (`recent.json`) and usage statistics (`usage.json`), in
// `WorkspacePath.localDirectory()`. Keeping them out of the synced file
// means it only changes when the user edits it, and one machine's paths
// never show up on another.

/// A directory learned from the shell's working-directory reports.
struct WorkspaceRecentDirectory: Hashable {
    var path: String
    var count: Int
    var lastVisited: Date

    init(path: String, count: Int = 1, lastVisited: Date) {
        self.path = path
        self.count = count
        self.lastVisited = lastVisited
    }

    /// Nil unless `path` is a non-empty string.
    init?(json: JSONValue) {
        guard let object = json.objectValue,
              let path = object["path"]?.stringValue, !path.isEmpty else { return nil }
        self.path = path
        self.count = max(1, object["count"]?.intValue ?? 1)
        self.lastVisited = object["lastVisited"]?.dateValue ?? .distantPast
    }

    var json: JSONValue {
        .object(["path": .string(path), "count": .int(Int64(count)), "lastVisited": .date(lastVisited)])
    }
}

/// `recent.json`: this machine's recent directories.
struct WorkspaceRecentDocument: Equatable {
    static let currentVersion = 1

    var recent: [WorkspaceRecentDirectory]

    init(recent: [WorkspaceRecentDirectory] = []) {
        self.recent = recent
    }

    init(json: JSONValue) {
        recent = (json.objectValue?["recent"]?.arrayValue ?? []).compactMap(WorkspaceRecentDirectory.init(json:))
    }

    var json: JSONValue {
        .object(["version": .int(Int64(Self.currentVersion)), "recent": .array(recent.map(\.json))])
    }

    /// Recent directories by frecency, most relevant first.
    func rankedRecent(now: Date = Date()) -> [WorkspaceRecentDirectory] {
        recent.sorted { lhs, rhs in
            let ls = WorkspaceFrecency.score(count: lhs.count, last: lhs.lastVisited, now: now)
            let rs = WorkspaceFrecency.score(count: rhs.count, last: rhs.lastVisited, now: now)
            if ls != rs { return ls > rs }
            return lhs.lastVisited > rhs.lastVisited
        }
    }

    /// Record a visit to an (already expanded, absolute) directory path.
    mutating func recordVisit(path: String, now: Date = Date()) {
        if let idx = recent.firstIndex(where: { $0.path == path }) {
            recent[idx].count += 1
            recent[idx].lastVisited = now
        } else {
            recent.append(WorkspaceRecentDirectory(path: path, count: 1, lastVisited: now))
        }
        if recent.count > WorkspaceFrecency.recentLimit {
            // Never evict the directory that was just visited: a brand-new
            // entry has the lowest possible count and could otherwise be
            // dropped immediately.
            let others = rankedRecent(now: now).filter { $0.path != path }
            let visited = recent.filter { $0.path == path }
            recent = Array(others.prefix(WorkspaceFrecency.recentLimit - visited.count)) + visited
        }
    }

    /// This machine's entries from a legacy `recent` array in workspace.json
    /// (which may also hold other machines' paths, e.g. `C:\...`).
    static func migrated(from legacy: [WorkspaceRecentDirectory]) -> WorkspaceRecentDocument {
        var doc = WorkspaceRecentDocument()
        for entry in legacy where WorkspacePath.isRecordable(entry.path) {
            if let idx = doc.recent.firstIndex(where: { $0.path == entry.path }) {
                doc.recent[idx].count += entry.count
                doc.recent[idx].lastVisited = max(doc.recent[idx].lastVisited, entry.lastVisited)
            } else {
                doc.recent.append(entry)
            }
        }
        doc.recent = Array(doc.rankedRecent().prefix(WorkspaceFrecency.recentLimit))
        return doc
    }
}

/// Usage statistics for one location or command.
struct WorkspaceUsage: Hashable {
    var count: Int
    var lastUsed: Date?
}

/// `usage.json`: this machine's usage statistics, keyed by entry id.
struct WorkspaceUsageDocument: Equatable {
    static let currentVersion = 1

    var entries: [UUID: WorkspaceUsage]

    init(entries: [UUID: WorkspaceUsage] = [:]) {
        self.entries = entries
    }

    init(json: JSONValue) {
        var entries: [UUID: WorkspaceUsage] = [:]
        for (key, value) in json.objectValue?["usage"]?.objectValue ?? [:] {
            guard let id = UUID(uuidString: key), let object = value.objectValue else { continue }
            entries[id] = WorkspaceUsage(
                count: max(0, object["useCount"]?.intValue ?? 0),
                lastUsed: object["lastUsed"]?.dateValue
            )
        }
        self.entries = entries
    }

    var json: JSONValue {
        var usage: [String: JSONValue] = [:]
        for (id, stats) in entries {
            var object: [String: JSONValue] = ["useCount": .int(Int64(stats.count))]
            if let last = stats.lastUsed { object["lastUsed"] = .date(last) }
            usage[id.uuidString] = .object(object)
        }
        return .object(["version": .int(Int64(Self.currentVersion)), "usage": .object(usage)])
    }

    /// This machine's statistics, or `seed` (the values an older version
    /// wrote into workspace.json) when the entry was never used here.
    func usage(for id: UUID, seed: WorkspaceUsage?) -> WorkspaceUsage? {
        entries[id] ?? seed
    }

    /// Count a use, starting from `seed` the first time.
    mutating func recordUse(id: UUID, seed: WorkspaceUsage?, now: Date) {
        var stats = usage(for: id, seed: seed) ?? WorkspaceUsage(count: 0, lastUsed: nil)
        stats.count += 1
        stats.lastUsed = now
        entries[id] = stats
    }
}
