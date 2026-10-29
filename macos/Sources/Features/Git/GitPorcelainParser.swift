import Foundation

/// Parses the output of `git status --porcelain=v2 --branch -z`.
///
/// This is a pure function over bytes. It never touches the filesystem or runs git,
/// so it is cheap to unit-test with fixtures. The `-z` form terminates every record
/// with NUL and emits rename records (`2 `) as two NUL-separated fields, which this
/// parser handles explicitly. Unknown records and malformed headers are ignored
/// rather than failing the whole parse: a partially understood status is more useful
/// to a status bar than none.
///
/// Reference: `git help status`, section "Porcelain Format Version 2".
enum GitPorcelainParser {
    /// Parsed result. Branch headers are optional because they are only emitted with
    /// `--branch`, and `stash` only with `--show-stash` (git 2.35+).
    struct Status: Equatable, Sendable {
        /// Commit the branch points at, or `nil` for an unborn branch (`(initial)`).
        var oid: String?
        /// Branch name, or `nil` when detached (`(detached)`).
        var head: String?
        /// Whether the `# branch.head` header reported a detached HEAD.
        var isDetached: Bool = false
        /// Upstream tracking ref, if configured.
        var upstream: String?
        var ahead: Int = 0
        var behind: Int = 0
        /// Stash entry count from `# stash N`, or `nil` when the header was absent.
        var stash: Int?

        var staged: Int = 0
        var unstaged: Int = 0
        var untracked: Int = 0
        var ignored: Int = 0
        var conflicted: Int = 0

        /// The first 7 characters of `oid`, used as the label for a detached HEAD.
        var shortOID: String? {
            guard let oid, !oid.isEmpty else { return nil }
            return String(oid.prefix(7))
        }
    }

    /// Parse raw stdout bytes. Entry records are classified on their raw bytes (the
    /// record type and the XY status are always ASCII), so paths with invalid UTF-8
    /// are still counted. Only header lines are decoded as text.
    static func parse(_ data: Data) -> Status {
        var status = Status()
        // Records are NUL-terminated. A trailing NUL produces an empty final record.
        var records = data.split(separator: 0, omittingEmptySubsequences: false)
        if records.last?.isEmpty == true {
            records.removeLast()
        }

        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let first = record.first else { continue }

            switch first {
            case UInt8(ascii: "#"):
                if let text = String(bytes: record, encoding: .utf8) {
                    parseHeader(text, into: &status)
                }
            case UInt8(ascii: "1"):
                parseChanged(record, into: &status)
            case UInt8(ascii: "2"):
                // Rename/copy: the record is followed by the original path as a
                // separate NUL-terminated field. Consume it so it is not misread
                // as another record.
                parseChanged(record, into: &status)
                index += 1
            case UInt8(ascii: "u"):
                status.conflicted += 1
            case UInt8(ascii: "?"):
                status.untracked += 1
            case UInt8(ascii: "!"):
                status.ignored += 1
            default:
                continue
            }
        }
        return status
    }

    /// Convenience for tests and callers holding a `String`. NUL must be present as
    /// `\0` in the string exactly as git emits it.
    static func parse(_ text: String) -> Status {
        parse(Data(text.utf8))
    }

    // MARK: Private

    private static func parseHeader(_ record: String, into status: inout Status) {
        // "# branch.oid <sha>" / "# branch.head <name>" / "# branch.upstream <ref>"
        // "# branch.ab +<n> -<m>" / "# stash <n>"
        let parts = record.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "#" else { return }
        let key = parts[1]
        let value = String(parts[2])

        switch key {
        case "branch.oid":
            status.oid = value == "(initial)" ? nil : value
        case "branch.head":
            if value == "(detached)" {
                status.head = nil
                status.isDetached = true
            } else {
                status.head = value
                status.isDetached = false
            }
        case "branch.upstream":
            status.upstream = value
        case "branch.ab":
            // "+N -M"
            for token in value.split(separator: " ") {
                guard let sign = token.first, let count = Int(token.dropFirst()) else { continue }
                if sign == "+" { status.ahead = count }
                if sign == "-" { status.behind = count }
            }
        case "stash":
            status.stash = Int(value)
        default:
            break
        }
    }

    /// `1 XY ...` and `2 XY ...` records share the same leading layout: record type,
    /// a space, then the two-character XY status.
    private static func parseChanged(_ record: Data.SubSequence, into status: inout Status) {
        // Need at least "1 XY". Slices keep the parent's indices, so offset from start.
        guard record.count >= 4 else { return }
        let start = record.startIndex
        guard record[start + 1] == UInt8(ascii: " ") else { return }
        let dot = UInt8(ascii: ".")
        if record[start + 2] != dot { status.staged += 1 }
        if record[start + 3] != dot { status.unstaged += 1 }
    }
}
