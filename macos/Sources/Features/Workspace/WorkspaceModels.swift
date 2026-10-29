import CryptoKit
import Foundation

// Slimer Workspace: models stored in `~/.config/slimer/workspace.json`.
//
// The file is user-owned, hand-edited, and synced between machines (macOS,
// and later Windows/Linux builds), so reading and writing it is lossless:
//
// - Keys Slimer does not know are kept verbatim on the document and on every
//   entry, and written back unchanged.
// - A known key whose value has the wrong type takes its default in memory,
//   and the original value is written back as long as the field is not
//   changed in the app.
// - An entry that cannot be used at all (not an object, no path/command) is
//   kept verbatim in its array position and never shown.
// - `useCount`/`lastUsed` (written by older versions) and `recent` are no
//   longer written; usage and recent directories are per machine (see
//   `WorkspaceLocalModels.swift`). The old values are kept verbatim and the
//   usage values seed the local statistics.

/// The key used for this OS in `paths` (locations) and `cwds` (commands).
enum WorkspacePlatform {
    static let current = "macos"
}

// MARK: - Raw fields

/// The parts of a JSON object Slimer does not manage itself, so they can be
/// written back unchanged.
struct WorkspaceRawFields: Hashable {
    /// A known key whose stored value could not be used.
    struct InvalidField: Hashable {
        /// The value from the file.
        var raw: JSONValue
        /// The value used instead (`.null` for an absent optional).
        var substitute: JSONValue
    }

    /// Keys Slimer does not know.
    var unknown: [String: JSONValue] = [:]
    /// Known keys with unusable values.
    var invalid: [String: InvalidField] = [:]

    /// Build the object to write: unknown keys, then each known field. A
    /// field that still holds the substitute for an unusable value writes the
    /// original value back; a nil field is left out.
    func object(_ fields: [(String, JSONValue?)]) -> [String: JSONValue] {
        var out = unknown
        for (key, value) in fields {
            if let invalid = invalid[key], (value ?? .null) == invalid.substitute {
                out[key] = invalid.raw
            } else if let value {
                out[key] = value
            }
        }
        return out
    }
}

/// Reads known keys from a JSON object, recording everything else in
/// `WorkspaceRawFields`.
private struct WorkspaceFieldReader {
    let object: [String: JSONValue]
    private(set) var raw: WorkspaceRawFields

    init(_ object: [String: JSONValue], known: Set<String>) {
        self.object = object
        self.raw = WorkspaceRawFields(unknown: object.filter { !known.contains($0.key) })
    }

    /// An optional field. A present value that does not parse is kept raw.
    mutating func optional<T>(_ key: String, _ parse: (JSONValue) -> T?) -> T? {
        guard let value = object[key] else { return nil }
        if let parsed = parse(value) { return parsed }
        raw.invalid[key] = .init(raw: value, substitute: .null)
        return nil
    }

    /// A field with a default. A present value that does not parse is kept raw.
    mutating func required<T>(
        _ key: String,
        default fallback: @autoclosure () -> T,
        encode: (T) -> JSONValue,
        _ parse: (JSONValue) -> T?
    ) -> T {
        guard let value = object[key] else { return fallback() }
        if let parsed = parse(value) { return parsed }
        let substitute = fallback()
        raw.invalid[key] = .init(raw: value, substitute: encode(substitute))
        return substitute
    }
}

private func nonEmptyString(_ value: JSONValue) -> String? {
    guard let string = value.stringValue, !string.isEmpty else { return nil }
    return string
}

private func uuidValue(_ value: JSONValue) -> UUID? {
    value.stringValue.flatMap(UUID.init(uuidString:))
}

private func uuidJSON(_ id: UUID) -> JSONValue {
    .string(id.uuidString)
}

/// A per-OS value from `paths`/`cwds`, if it is a non-empty string.
private func platformValue(_ values: [String: JSONValue]?, _ platform: String) -> String? {
    guard let string = values?[platform]?.stringValue,
          !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return string
}

private func nonBlank(_ string: String?) -> String? {
    guard let string, !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return string
}

/// A stable id for an entry without one, derived from its content so it is
/// the same on every launch (usage statistics are keyed by id) until the
/// entry is saved with that id.
private func derivedID(kind: String, object: [String: JSONValue], salt: Int? = nil) -> UUID {
    var input = Data("slimer.workspace.\(kind)".utf8)
    if let salt { input.append(Data(":\(salt)".utf8)) }
    input.append((try? JSONValue.object(object).encodedFile()) ?? Data())
    var bytes = Array(SHA256.hash(data: input).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5 style
    bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

/// Usage values written by older versions into an entry (`useCount`,
/// `lastUsed`); they seed the per-machine statistics.
private func workspaceLegacyUsage(_ raw: WorkspaceRawFields) -> WorkspaceUsage? {
    let count = raw.unknown["useCount"]?.intValue
    let last = raw.unknown["lastUsed"]?.dateValue
    guard count != nil || last != nil else { return nil }
    return WorkspaceUsage(count: max(0, count ?? 0), lastUsed: last)
}

// MARK: - Location

/// A frequently used directory.
struct WorkspaceLocation: Identifiable, Hashable {
    static let knownKeys: Set<String> = [
        "id", "name", "path", "paths", "icon", "color", "pinned", "shortcut", "startupCommand", "startupConfirm",
    ]

    var id: UUID
    var name: String
    /// The portable path, used when `paths` has no value for this OS. `~` is
    /// allowed and expanded at use time (see `WorkspacePath.expand`).
    var path: String?
    /// Per-OS paths (`macos`, `windows`, `linux`); other keys and values are
    /// kept as they are.
    var paths: [String: JSONValue]?
    /// Optional SF Symbol name.
    var icon: String?
    /// Optional hex color (`#RRGGBB`).
    var color: String?
    var pinned: Bool
    /// Ghostty-style shortcut, e.g. `cmd+shift+1`.
    var shortcut: String?
    /// Command typed into the shell when the location is opened in a new
    /// tab/split/window.
    var startupCommand: String?
    /// When true (the default) the startup command is only typed and the user
    /// presses Enter. When false, Enter is pressed too.
    var startupConfirm: Bool
    /// Keys this version does not manage, written back unchanged.
    var raw = WorkspaceRawFields()

    init(
        id: UUID = UUID(),
        name: String,
        path: String?,
        paths: [String: JSONValue]? = nil,
        icon: String? = nil,
        color: String? = nil,
        pinned: Bool = false,
        shortcut: String? = nil,
        startupCommand: String? = nil,
        startupConfirm: Bool = true
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.paths = paths
        self.icon = icon
        self.color = color
        self.pinned = pinned
        self.shortcut = shortcut
        self.startupCommand = startupCommand
        self.startupConfirm = startupConfirm
    }

    /// Parse an entry (`idSalt`: see `WorkspaceDocument.parse`). Nil when it
    /// is not usable on any OS (not an object, or
    /// neither `path` nor any `paths` value is a non-empty string).
    init?(json: JSONValue, idSalt: Int? = nil) {
        guard let object = json.objectValue else { return nil }
        var reader = WorkspaceFieldReader(object, known: Self.knownKeys)
        let path = reader.optional("path", nonEmptyString)
        let paths = reader.optional("paths", \.objectValue)
        let anyPlatformPath = paths?.keys.sorted().lazy.compactMap { platformValue(paths, $0) }.first
        guard let fallbackPath = path ?? anyPlatformPath else { return nil }
        self.path = path
        self.paths = paths
        self.id = reader.required(
            "id",
            default: derivedID(kind: "location", object: object, salt: idSalt),
            encode: uuidJSON,
            uuidValue
        )
        let displayPath = platformValue(paths, WorkspacePlatform.current) ?? fallbackPath
        self.name = reader.required("name", default: WorkspacePath.displayName(for: displayPath), encode: JSONValue.string, \.stringValue)
        self.icon = reader.optional("icon", \.stringValue)
        self.color = reader.optional("color", \.stringValue)
        self.pinned = reader.required("pinned", default: false, encode: JSONValue.bool, \.boolValue)
        self.shortcut = reader.optional("shortcut", \.stringValue)
        self.startupCommand = reader.optional("startupCommand", \.stringValue)
        self.startupConfirm = reader.required("startupConfirm", default: true, encode: JSONValue.bool, \.boolValue)
        self.raw = reader.raw
    }

    var json: JSONValue {
        .object(raw.object([
            ("id", .string(id.uuidString)),
            ("name", .string(name)),
            ("path", path.map(JSONValue.string)),
            ("paths", paths.map(JSONValue.object)),
            ("icon", icon.map(JSONValue.string)),
            ("color", color.map(JSONValue.string)),
            ("pinned", .bool(pinned)),
            ("shortcut", shortcut.map(JSONValue.string)),
            ("startupCommand", startupCommand.map(JSONValue.string)),
            ("startupConfirm", .bool(startupConfirm)),
        ]))
    }

    /// The path for this OS: `paths.macos` if set, else `path`.
    var currentPath: String? {
        platformValue(paths, WorkspacePlatform.current) ?? nonBlank(path)
    }

    /// The path for this OS with `~` expanded ("" when there is none).
    var expandedPath: String { WorkspacePath.expand(currentPath ?? "") }

    /// Whether the location has a usable (absolute) path on this OS. Others
    /// (only a Windows path, `C:\...`) are kept in the file but hidden.
    var isAvailable: Bool { expandedPath.hasPrefix("/") }

    /// The path Settings edits: `paths.macos` when the entry has one,
    /// otherwise the portable `path`.
    var editablePath: String {
        get { paths?[WorkspacePlatform.current]?.stringValue ?? path ?? "" }
        set {
            if var paths, paths[WorkspacePlatform.current]?.stringValue != nil {
                paths[WorkspacePlatform.current] = .string(newValue)
                self.paths = paths
            } else {
                path = newValue
            }
        }
    }

    /// Apply the fields Settings edits from `draft`, keeping everything else
    /// (other OS paths, unknown keys) as this entry has it.
    mutating func applyEdits(from draft: WorkspaceLocation) {
        name = draft.name
        editablePath = draft.editablePath
        icon = draft.icon
        color = draft.color
        pinned = draft.pinned
        shortcut = draft.shortcut
        startupCommand = draft.startupCommand
        startupConfirm = draft.startupConfirm
    }

    /// `useCount`/`lastUsed` from the file (written by older versions).
    var legacyUsage: WorkspaceUsage? { workspaceLegacyUsage(raw) }

    /// The startup command without surrounding whitespace, or nil if empty.
    var trimmedStartupCommand: String? {
        guard let cmd = startupCommand?.trimmingCharacters(in: .whitespaces), !cmd.isEmpty else { return nil }
        return cmd
    }

    var hasStartupCommand: Bool { trimmedStartupCommand != nil }
}

// MARK: - Command

/// A saved shell command.
struct WorkspaceCommand: Identifiable, Hashable {
    static let knownKeys: Set<String> = ["id", "name", "command", "cwd", "cwds", "pinned", "shortcut", "confirm"]

    var id: UUID
    var name: String
    var command: String
    /// Optional directory to `cd` into before running (`~` allowed), used
    /// when `cwds` has no value for this OS.
    var cwd: String?
    /// Per-OS directories (`macos`, `windows`, `linux`).
    var cwds: [String: JSONValue]?
    var pinned: Bool
    var shortcut: String?
    /// When true (the default) the command text is only inserted into the
    /// terminal and the user presses Enter. When false, Enter is pressed too.
    var confirm: Bool
    /// Keys this version does not manage, written back unchanged.
    var raw = WorkspaceRawFields()

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        cwd: String? = nil,
        cwds: [String: JSONValue]? = nil,
        pinned: Bool = false,
        shortcut: String? = nil,
        confirm: Bool = true
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
        self.cwds = cwds
        self.pinned = pinned
        self.shortcut = shortcut
        self.confirm = confirm
    }

    /// Parse an entry (`idSalt`: see `WorkspaceDocument.parse`). Nil when it
    /// is not an object or has no command.
    init?(json: JSONValue, idSalt: Int? = nil) {
        guard let object = json.objectValue else { return nil }
        var reader = WorkspaceFieldReader(object, known: Self.knownKeys)
        guard let command = reader.optional("command", nonEmptyString) else { return nil }
        self.command = command
        self.id = reader.required(
            "id",
            default: derivedID(kind: "command", object: object, salt: idSalt),
            encode: uuidJSON,
            uuidValue
        )
        self.name = reader.required("name", default: command, encode: JSONValue.string, \.stringValue)
        self.cwd = reader.optional("cwd", \.stringValue)
        self.cwds = reader.optional("cwds", \.objectValue)
        self.pinned = reader.required("pinned", default: false, encode: JSONValue.bool, \.boolValue)
        self.shortcut = reader.optional("shortcut", \.stringValue)
        self.confirm = reader.required("confirm", default: true, encode: JSONValue.bool, \.boolValue)
        self.raw = reader.raw
    }

    var json: JSONValue {
        .object(raw.object([
            ("id", .string(id.uuidString)),
            ("name", .string(name)),
            ("command", .string(command)),
            ("cwd", cwd.map(JSONValue.string)),
            ("cwds", cwds.map(JSONValue.object)),
            ("pinned", .bool(pinned)),
            ("shortcut", shortcut.map(JSONValue.string)),
            ("confirm", .bool(confirm)),
        ]))
    }

    /// The directory for this OS, trimmed: `cwds.macos` if set, else `cwd`.
    var currentCwd: String? {
        (platformValue(cwds, WorkspacePlatform.current) ?? nonBlank(cwd))?.trimmingCharacters(in: .whitespaces)
    }

    /// Whether any directory is configured, for any OS.
    private var hasAnyCwd: Bool {
        nonBlank(cwd) != nil || (cwds?.keys.contains { platformValue(cwds, $0) != nil } ?? false)
    }

    /// Whether the command can run on this OS: it has no directory at all, or
    /// its directory for this OS is absolute. A command whose only directory
    /// is for another OS is kept in the file but hidden.
    var isAvailable: Bool {
        if let currentCwd { return WorkspacePath.expand(currentCwd).hasPrefix("/") }
        return !hasAnyCwd
    }

    /// The directory Settings edits: `cwds.macos` when the entry has one,
    /// otherwise the portable `cwd`.
    var editableCwd: String? {
        get { cwds?[WorkspacePlatform.current]?.stringValue ?? cwd }
        set {
            if var cwds, cwds[WorkspacePlatform.current]?.stringValue != nil {
                cwds[WorkspacePlatform.current] = newValue.map(JSONValue.string)
                self.cwds = cwds
            } else {
                cwd = newValue
            }
        }
    }

    /// Apply the fields Settings edits from `draft`, keeping everything else
    /// (other OS directories, unknown keys) as this entry has it.
    mutating func applyEdits(from draft: WorkspaceCommand) {
        name = draft.name
        command = draft.command
        editableCwd = draft.editableCwd
        pinned = draft.pinned
        shortcut = draft.shortcut
        confirm = draft.confirm
    }

    /// `useCount`/`lastUsed` from the file (written by older versions).
    var legacyUsage: WorkspaceUsage? { workspaceLegacyUsage(raw) }
}

/// An array entry this version cannot use, kept verbatim at its position.
struct WorkspaceUnusableEntry: Hashable {
    /// Index in the array as read from the file.
    var index: Int
    var value: JSONValue
}

// MARK: - Document

/// The whole `workspace.json` document.
struct WorkspaceDocument: Equatable {
    static let currentVersion = 1
    static let knownKeys: Set<String> = ["version", "locations", "commands"]

    var version: Int
    /// Every usable location, including ones hidden on this OS (see
    /// `visibleLocations`), in file order.
    var locations: [WorkspaceLocation]
    var commands: [WorkspaceCommand]
    /// Entries that could not be parsed, written back at their positions.
    var unusableLocations: [WorkspaceUnusableEntry] = []
    var unusableCommands: [WorkspaceUnusableEntry] = []
    /// Keys this version does not manage (including the legacy `recent`).
    var raw = WorkspaceRawFields()

    init(
        version: Int = WorkspaceDocument.currentVersion,
        locations: [WorkspaceLocation] = [],
        commands: [WorkspaceCommand] = []
    ) {
        self.version = version
        self.locations = locations
        self.commands = commands
    }

    init(json: JSONValue) throws {
        guard let object = json.objectValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "workspace.json is not an object"))
        }
        var reader = WorkspaceFieldReader(object, known: Self.knownKeys)
        version = reader.required("version", default: Self.currentVersion, encode: { .int(Int64($0)) }, \.intValue)

        let locationItems = reader.required("locations", default: [], encode: JSONValue.array, \.arrayValue)
        (locations, unusableLocations) = Self.parse(locationItems, WorkspaceLocation.init(json:idSalt:))

        let commandItems = reader.required("commands", default: [], encode: JSONValue.array, \.arrayValue)
        (commands, unusableCommands) = Self.parse(commandItems, WorkspaceCommand.init(json:idSalt:))

        raw = reader.raw
    }

    /// Parse an array, keeping unusable items with their index. Identical
    /// entries without an id would derive the same id; later copies derive
    /// theirs with the index mixed in so lists and edits can tell them apart.
    private static func parse<T: Identifiable>(
        _ items: [JSONValue],
        _ make: (JSONValue, Int?) -> T?
    ) -> ([T], [WorkspaceUnusableEntry]) where T.ID == UUID {
        var parsed: [T] = []
        var unusable: [WorkspaceUnusableEntry] = []
        var seen: Set<UUID> = []
        for (index, item) in items.enumerated() {
            guard var value = make(item, nil) else {
                unusable.append(WorkspaceUnusableEntry(index: index, value: item))
                continue
            }
            let hasOwnID = item.objectValue?["id"].flatMap(uuidValue) != nil
            if seen.contains(value.id), !hasOwnID, let salted = make(item, index) {
                value = salted
            }
            seen.insert(value.id)
            parsed.append(value)
        }
        return (parsed, unusable)
    }

    var json: JSONValue {
        .object(raw.object([
            ("version", .int(Int64(version))),
            ("locations", .array(Self.interleave(locations.map(\.json), unusableLocations))),
            ("commands", .array(Self.interleave(commands.map(\.json), unusableCommands))),
        ]))
    }

    /// Put unusable entries back at their original indices, filling the other
    /// slots with the usable entries in order.
    static func interleave(_ entries: [JSONValue], _ unusable: [WorkspaceUnusableEntry]) -> [JSONValue] {
        var out: [JSONValue] = []
        var pending = entries[...]
        var kept = unusable.sorted { $0.index < $1.index }[...]
        while !pending.isEmpty || !kept.isEmpty {
            if let next = kept.first, next.index <= out.count || pending.isEmpty {
                out.append(next.value)
                kept.removeFirst()
            } else {
                out.append(pending.removeFirst())
            }
        }
        return out
    }

    /// A file from a newer Slimer: shown, but never written.
    var isNewerVersion: Bool { version > Self.currentVersion }

    /// How many entries are kept in the file but cannot be used at all.
    var unusableCount: Int { unusableLocations.count + unusableCommands.count }

    /// Locations usable on this OS, in file order.
    var visibleLocations: [WorkspaceLocation] { locations.filter(\.isAvailable) }

    /// Commands usable on this OS, in file order.
    var visibleCommands: [WorkspaceCommand] { commands.filter(\.isAvailable) }

    /// The `recent` array written by older versions (all machines' entries).
    var legacyRecent: [WorkspaceRecentDirectory] {
        (raw.unknown["recent"]?.arrayValue ?? []).compactMap(WorkspaceRecentDirectory.init(json:))
    }

    /// The first-run document.
    static func seed() -> WorkspaceDocument {
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

    /// Visible locations: pinned first, then by frecency, then by name.
    func rankedLocations(usage: WorkspaceUsageDocument = WorkspaceUsageDocument(), now: Date = Date()) -> [WorkspaceLocation] {
        let scored = visibleLocations.map { location in
            let stats = usage.usage(for: location.id, seed: location.legacyUsage)
            return (location, WorkspaceFrecency.score(count: stats?.count ?? 0, last: stats?.lastUsed, now: now))
        }
        return scored.sorted { lhs, rhs in
            if lhs.0.pinned != rhs.0.pinned { return lhs.0.pinned }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }.map(\.0)
    }

    /// Visible commands: pinned first, then by frecency, then by name.
    func rankedCommands(usage: WorkspaceUsageDocument = WorkspaceUsageDocument(), now: Date = Date()) -> [WorkspaceCommand] {
        let scored = visibleCommands.map { command in
            let stats = usage.usage(for: command.id, seed: command.legacyUsage)
            return (command, WorkspaceFrecency.score(count: stats?.count ?? 0, last: stats?.lastUsed, now: now))
        }
        return scored.sorted { lhs, rhs in
            if lhs.0.pinned != rhs.0.pinned { return lhs.0.pinned }
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }.map(\.0)
    }

    // MARK: Editing visible entries

    /// Reorder like `move(fromOffsets:toOffset:)` with offsets into
    /// `visibleLocations`; hidden entries keep their slots.
    mutating func moveVisibleLocations(fromOffsets source: IndexSet, toOffset destination: Int) {
        locations = Self.moveVisible(locations, isVisible: \.isAvailable, fromOffsets: source, toOffset: destination)
    }

    /// Reorder like `move(fromOffsets:toOffset:)` with offsets into
    /// `visibleCommands`; hidden entries keep their slots.
    mutating func moveVisibleCommands(fromOffsets source: IndexSet, toOffset destination: Int) {
        commands = Self.moveVisible(commands, isVisible: \.isAvailable, fromOffsets: source, toOffset: destination)
    }

    private static func moveVisible<T>(
        _ items: [T],
        isVisible: (T) -> Bool,
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [T] {
        let slots = items.indices.filter { isVisible(items[$0]) }
        var visible = slots.map { items[$0] }
        guard source.allSatisfy(visible.indices.contains), destination >= 0, destination <= visible.count else {
            return items
        }
        visible.move(fromOffsets: source, toOffset: destination)
        var result = items
        for (slot, item) in zip(slots, visible) { result[slot] = item }
        return result
    }

    // MARK: JSON

    static func decode(_ data: Data) throws -> WorkspaceDocument {
        try WorkspaceDocument(json: JSONValue.decode(data))
    }

    func encoded() throws -> Data {
        try json.encodedFile()
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
