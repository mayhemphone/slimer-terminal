import Foundation

/// Any JSON value. The Workspace files use it to keep keys and entries Slimer
/// does not understand (written by a newer Slimer or another platform's
/// build) and write them back unchanged.
///
/// Numbers are kept as `Int64` when they are whole numbers that fit, otherwise
/// as `Double`, so `42` stays `42`. Formatting (whitespace, key order) is not
/// preserved: files are always written pretty printed with sorted keys.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Typed access (nil when the value has another type)

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Whole numbers only (`3` or `3.0`); anything else is nil.
    var intValue: Int? {
        switch self {
        case .int(let value): return Int(exactly: value)
        case .double(let value): return Int(exactly: value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    // MARK: Dates

    /// An ISO 8601 string (with or without fractional seconds) or epoch
    /// seconds, as written by Slimer or other tools.
    var dateValue: Date? {
        switch self {
        case .string(let string):
            return Self.iso8601Fractional.date(from: string) ?? Self.iso8601.date(from: string)
        case .int, .double:
            return doubleValue.map(Date.init(timeIntervalSince1970:))
        default:
            return nil
        }
    }

    /// A date as Slimer writes it: ISO 8601, whole seconds, UTC.
    static func date(_ date: Date) -> JSONValue {
        .string(iso8601.string(from: date))
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

    // MARK: Files

    /// Parse a whole file.
    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Serialize the way all Slimer JSON files are written: pretty printed,
    /// sorted keys, unescaped slashes, trailing newline.
    func encodedFile() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A) // trailing newline, friendlier for editors and diffs
        return data
    }
}
