import Foundation

/// POSIX shell quoting for values that end up inside command text inserted into
/// the terminal.
///
/// The app never executes these strings itself; they are typed into the user's
/// shell where the user can read them before pressing Enter. Quoting still
/// matters because a hostile branch name must not be able to smuggle a second
/// command into that text. Per `docs/slimer/CONVENTIONS.md`, unsafe input is
/// rejected, not stripped.
enum GitShellQuoting {
    enum ValidationError: Error, Equatable {
        case empty
        /// C0/C1 control characters, DEL, U+2028/U+2029 or bidi overrides.
        case containsControlCharacters
        /// A leading `-` could be parsed as an option by the shell command.
        case leadingDash
    }

    /// Characters that never need quoting in a POSIX shell word.
    private static let safeScalars: Set<Unicode.Scalar> = {
        var set = Set<Unicode.Scalar>()
        for scalar in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./@".unicodeScalars {
            set.insert(scalar)
        }
        return set
    }()

    /// Throws if `argument` may not be placed in terminal text at all.
    static func validate(_ argument: String) throws {
        guard !argument.isEmpty else { throw ValidationError.empty }
        guard !argument.hasPrefix("-") else { throw ValidationError.leadingDash }
        for scalar in argument.unicodeScalars where isForbidden(scalar) {
            throw ValidationError.containsControlCharacters
        }
    }

    /// `true` when `validate` would succeed.
    static func isSafe(_ argument: String) -> Bool {
        (try? validate(argument)) != nil
    }

    /// Returns `argument` ready to be pasted as one shell word. Plain identifiers are
    /// returned unchanged; anything else is wrapped in single quotes with embedded
    /// single quotes escaped as `'\''`.
    static func quote(_ argument: String) throws -> String {
        try validate(argument)
        if argument.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x80...0x9F:
            return true // C0, DEL, C1
        case 0x2028, 0x2029:
            return true // line/paragraph separator
        case 0x202A...0x202E, 0x2066...0x2069:
            return true // bidi embeddings, overrides and isolates
        default:
            return false
        }
    }
}

/// One entry in the git popover menu: a title, an icon, and the exact command text
/// the UI will insert into the terminal. Actions are data; nothing here runs git.
struct GitAction: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case fetch
        case pull
        case push
        case stashPush
        case stashPop
        case switchBranch
        case createBranch
    }

    enum CommandError: Error, Equatable {
        /// The action needs a branch but HEAD is detached.
        case detachedHead
        /// The branch or ref name failed `GitShellQuoting.validate`.
        case invalidName(GitShellQuoting.ValidationError)
    }

    let kind: Kind
    let title: String
    let systemImage: String
    /// Branch name for `switchBranch` / `createBranch`; `nil` otherwise.
    let argument: String?

    var id: String {
        if let argument { return "\(kind.rawValue):\(argument)" }
        return kind.rawValue
    }

    /// Whether the action makes sense for `state`. The UI hides or disables
    /// unavailable actions; `commandLine(for:)` still works for most of them.
    func isAvailable(for state: GitRepoState) -> Bool {
        switch kind {
        case .fetch, .createBranch:
            return true
        case .pull:
            return state.upstream != nil
        case .push:
            return state.upstream != nil || state.branch != nil
        case .stashPush:
            return state.staged > 0 || state.unstaged > 0 || state.conflicted > 0
        case .stashPop:
            return state.stashCount > 0
        case .switchBranch:
            return argument != state.branch
        }
    }

    /// The exact shell text to insert. Branch names are quoted; names that fail
    /// validation make this throw rather than producing a sanitized command.
    func commandLine(for state: GitRepoState) throws -> String {
        switch kind {
        case .fetch:
            return "git fetch --all --prune"
        case .pull:
            return "git pull --ff-only"
        case .push:
            if state.upstream != nil {
                return "git push"
            }
            guard let branch = state.branch else { throw CommandError.detachedHead }
            return "git push -u origin \(try quoted(branch))"
        case .stashPush:
            return "git stash push"
        case .stashPop:
            return "git stash pop"
        case .switchBranch:
            return "git switch \(try quoted(argument ?? ""))"
        case .createBranch:
            return "git switch -c \(try quoted(argument ?? ""))"
        }
    }

    private func quoted(_ name: String) throws -> String {
        do {
            return try GitShellQuoting.quote(name)
        } catch let error as GitShellQuoting.ValidationError {
            throw CommandError.invalidName(error)
        }
    }
}

/// The catalogue of actions the git popover offers.
enum GitActions {
    static let fetch = GitAction(kind: .fetch, title: "Fetch", systemImage: "arrow.triangle.2.circlepath", argument: nil)
    static let pull = GitAction(kind: .pull, title: "Pull (fast-forward)", systemImage: "arrow.down.circle", argument: nil)
    static let push = GitAction(kind: .push, title: "Push", systemImage: "arrow.up.circle", argument: nil)
    static let stashPush = GitAction(kind: .stashPush, title: "Stash Changes", systemImage: "tray.and.arrow.down", argument: nil)
    static let stashPop = GitAction(kind: .stashPop, title: "Pop Stash", systemImage: "tray.and.arrow.up", argument: nil)

    /// The fixed actions, in menu order.
    static let standard: [GitAction] = [fetch, pull, push, stashPush, stashPop]

    /// The fixed actions that apply to `state`.
    static func available(for state: GitRepoState) -> [GitAction] {
        standard.filter { $0.isAvailable(for: state) }
    }

    static func switchBranch(to name: String) -> GitAction {
        GitAction(kind: .switchBranch, title: "Switch to \(name)", systemImage: "arrow.triangle.branch", argument: name)
    }

    static func createBranch(named name: String) -> GitAction {
        GitAction(kind: .createBranch, title: "Create Branch \(name)", systemImage: "plus.circle", argument: name)
    }

    /// Branch names for the switch menu. A read-only query with a 2 s timeout,
    /// served by `GitStatusService`.
    @MainActor
    static func branchList(root: URL) async -> [String] {
        await GitStatusService.shared.branchList(root: root)
    }
}
