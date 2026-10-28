import Foundation

// Slimer Workspace: Codable models stored in `~/.config/slimer/workspace.json`.
//
// Decoding is deliberately tolerant: unknown keys are ignored, missing optional
// keys take defaults, and a single malformed entry is dropped instead of failing
// the whole document. The file is user-owned and may be hand-edited or synced.

/// A frequently used directory.
struct WorkspaceLocation: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// The path. `~` is allowed and expanded at use time (see `WorkspacePath.expand`).
    var path: String
    /// Optional SF Symbol name.
    var icon: String?
    /// Optional hex color (`#RRGGBB`).
    var color: String?
    var pinned: Bool
    /// Ghostty-style shortcut, e.g. `cmd+shift+1`.
    var shortcut: String?
    /// Command to run when the location is opened in a new tab/split/window.
    var startupCommand: String?
    /// Usage statistics for frecency ranking.
    var useCount: Int
    var lastUsed: Date?

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        icon: String? = nil,
        color: String? = nil,
        pinned: Bool = false,
        shortcut: String? = nil,
        startupCommand: String? = nil,
        useCount: Int = 0,
        lastUsed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.icon = icon
        self.color = color
        self.pinned = pinned
        self.shortcut = shortcut
        self.startupCommand = startupCommand
        self.useCount = useCount
        self.lastUsed = lastUsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        guard !path.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "empty path")
        }
        self.path = path
        self.id = c.tolerantDecode(UUID.self, forKey: .id) ?? UUID()
        self.name = c.tolerantDecode(String.self, forKey: .name) ?? WorkspacePath.displayName(for: path)
        self.icon = c.tolerantDecode(String.self, forKey: .icon)
        self.color = c.tolerantDecode(String.self, forKey: .color)
        self.pinned = c.tolerantDecode(Bool.self, forKey: .pinned) ?? false
        self.shortcut = c.tolerantDecode(String.self, forKey: .shortcut)
        self.startupCommand = c.tolerantDecode(String.self, forKey: .startupCommand)
        self.useCount = max(0, c.tolerantDecode(Int.self, forKey: .useCount) ?? 0)
        self.lastUsed = c.tolerantDecode(Date.self, forKey: .lastUsed)
    }

    /// The path with `~` expanded.
    var expandedPath: String { WorkspacePath.expand(path) }
}

/// A saved shell command.
struct WorkspaceCommand: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var command: String
    /// Optional directory to `cd` into before running (`~` allowed).
    var cwd: String?
    var pinned: Bool
    var shortcut: String?
    /// When true (the default) the command text is only inserted into the
    /// terminal and the user presses Enter. When false, Enter is pressed too.
    var confirm: Bool
    var useCount: Int
    var lastUsed: Date?

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        cwd: String? = nil,
        pinned: Bool = false,
        shortcut: String? = nil,
        confirm: Bool = true,
        useCount: Int = 0,
        lastUsed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
        self.pinned = pinned
        self.shortcut = shortcut
        self.confirm = confirm
        self.useCount = useCount
        self.lastUsed = lastUsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let command = try c.decode(String.self, forKey: .command)
        guard !command.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .command, in: c, debugDescription: "empty command")
        }
        self.command = command
        self.id = c.tolerantDecode(UUID.self, forKey: .id) ?? UUID()
        self.name = c.tolerantDecode(String.self, forKey: .name) ?? command
        self.cwd = c.tolerantDecode(String.self, forKey: .cwd)
        self.pinned = c.tolerantDecode(Bool.self, forKey: .pinned) ?? false
        self.shortcut = c.tolerantDecode(String.self, forKey: .shortcut)
        self.confirm = c.tolerantDecode(Bool.self, forKey: .confirm) ?? true
        self.useCount = max(0, c.tolerantDecode(Int.self, forKey: .useCount) ?? 0)
        self.lastUsed = c.tolerantDecode(Date.self, forKey: .lastUsed)
    }
}

/// A directory learned from the shell's working-directory reports.
struct WorkspaceRecentDirectory: Codable, Hashable {
    var path: String
    var count: Int
    var lastVisited: Date

    init(path: String, count: Int = 1, lastVisited: Date) {
        self.path = path
        self.count = count
        self.lastVisited = lastVisited
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = try c.decode(String.self, forKey: .path)
        guard !path.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "empty path")
        }
        self.path = path
        self.count = max(1, c.tolerantDecode(Int.self, forKey: .count) ?? 1)
        self.lastVisited = c.tolerantDecode(Date.self, forKey: .lastVisited) ?? .distantPast
    }
}

/// Frecency scoring shared by locations, commands and recent directories.
enum WorkspaceFrecency {
    /// Maximum number of recent directories kept on disk.
    static let recentLimit = 50

    /// zoxide-style score: usage count weighted by how recently it was used.
    static func score(count: Int, last: Date?, now: Date) -> Double {
        guard let last else { return 0 }
        let age = now.timeIntervalSince(last)
        let weight: Double
        if age < 3600 {
            weight = 4
        } else if age < 86_400 {
            weight = 2
        } else if age < 7 * 86_400 {
            weight = 0.5
        } else {
            weight = 0.25
        }
        return Double(count) * weight
    }
}

/// The whole `workspace.json` document.
struct WorkspaceDocument: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var locations: [WorkspaceLocation]
    var commands: [WorkspaceCommand]
    var recent: [WorkspaceRecentDirectory]

    init(
        version: Int = WorkspaceDocument.currentVersion,
        locations: [WorkspaceLocation] = [],
        commands: [WorkspaceCommand] = [],
        recent: [WorkspaceRecentDirectory] = []
    ) {
        self.version = version
        self.locations = locations
        self.commands = commands
        self.recent = recent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = c.tolerantDecode(Int.self, forKey: .version) ?? WorkspaceDocument.currentVersion
        self.locations = c.tolerantDecodeArray(WorkspaceLocation.self, forKey: .locations)
        self.commands = c.tolerantDecodeArray(WorkspaceCommand.self, forKey: .commands)
        self.recent = c.tolerantDecodeArray(WorkspaceRecentDirectory.self, forKey: .recent)
    }

    /// The first-run document.
    static func seed(home: String = NSHomeDirectory()) -> WorkspaceDocument {
        WorkspaceDocument(
            locations: [
                WorkspaceLocation(name: "Home", path: "~", icon: "house", pinned: true),
                WorkspaceLocation(name: "Dev", path: "~/Dev", icon: "folder", pinned: true),
                WorkspaceLocation(
                    name: "league-view-backend",
                    path: "~/Dev/league-view-backend",
                    icon: "server.rack",
                    pinned: true
                ),
            ],
            commands: [
                WorkspaceCommand(name: "Claude", command: "claude", pinned: true),
                WorkspaceCommand(name: "Claude (continue)", command: "claude --continue", pinned: true),
                WorkspaceCommand(name: "git status", command: "git status"),
            ]
        )
    }

    // MARK: Ranking

    /// Pinned first, then by frecency, then by name.
    func rankedLocations(now: Date = Date()) -> [WorkspaceLocation] {
        locations.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            let ls = WorkspaceFrecency.score(count: lhs.useCount, last: lhs.lastUsed, now: now)
            let rs = WorkspaceFrecency.score(count: rhs.useCount, last: rhs.lastUsed, now: now)
            if ls != rs { return ls > rs }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Pinned first, then by frecency, then by name.
    func rankedCommands(now: Date = Date()) -> [WorkspaceCommand] {
        commands.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            let ls = WorkspaceFrecency.score(count: lhs.useCount, last: lhs.lastUsed, now: now)
            let rs = WorkspaceFrecency.score(count: rhs.useCount, last: rhs.lastUsed, now: now)
            if ls != rs { return ls > rs }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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

    // MARK: Mutation

    /// Record a visit to an (already expanded, absolute) directory path.
    mutating func recordVisit(path: String, now: Date = Date()) {
        if let idx = recent.firstIndex(where: { $0.path == path }) {
            recent[idx].count += 1
            recent[idx].lastVisited = now
        } else {
            recent.append(WorkspaceRecentDirectory(path: path, count: 1, lastVisited: now))
        }
        if recent.count > WorkspaceFrecency.recentLimit {
            recent = Array(rankedRecent(now: now).prefix(WorkspaceFrecency.recentLimit))
        }
    }

    /// Record a use of a location. Returns false if the id is unknown.
    @discardableResult
    mutating func recordUse(locationID id: UUID, now: Date = Date()) -> Bool {
        guard let idx = locations.firstIndex(where: { $0.id == id }) else { return false }
        locations[idx].useCount += 1
        locations[idx].lastUsed = now
        return true
    }

    /// Record a use of a command. Returns false if the id is unknown.
    @discardableResult
    mutating func recordUse(commandID id: UUID, now: Date = Date()) -> Bool {
        guard let idx = commands.firstIndex(where: { $0.id == id }) else { return false }
        commands[idx].useCount += 1
        commands[idx].lastUsed = now
        return true
    }

    // MARK: JSON

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = iso8601Fractional.date(from: string) ?? iso8601.date(from: string) {
                    return date
                }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date: \(string)")
            }
            // Tolerate epoch seconds written by other tools.
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSince1970: seconds)
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601.string(from: date))
        }
        return encoder
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func decode(_ data: Data) throws -> WorkspaceDocument {
        try makeDecoder().decode(WorkspaceDocument.self, from: data)
    }

    func encoded() throws -> Data {
        var data = try WorkspaceDocument.makeEncoder().encode(self)
        data.append(0x0A) // trailing newline, friendlier for editors and diffs
        return data
    }
}

// MARK: - Tolerant decoding helpers

private struct WorkspaceFailable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    /// Decode a value, treating a missing, null, or wrongly-typed value as nil.
    func tolerantDecode<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// Decode an array, dropping entries that fail to decode. A missing or
    /// malformed array yields an empty array.
    func tolerantDecodeArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard let items = (try? decodeIfPresent([WorkspaceFailable<T>].self, forKey: key)) ?? nil else {
            return []
        }
        return items.compactMap(\.value)
    }
}
