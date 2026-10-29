import AppKit
import SwiftUI

/// A branch shown in the popover's switch list.
struct GitBranchRef: Equatable, Hashable, Identifiable, Sendable {
    /// Display name (`main`, `origin/feature`).
    let name: String
    /// The name `git switch` takes: the local name, or the remote branch name
    /// without its remote (git's DWIM then creates a tracking branch).
    let switchName: String
    let isRemote: Bool

    var id: String { name }

    /// Build the list from full ref names (`refs/heads/x`, `refs/remotes/o/x`).
    /// `remotes` are the configured remote names (`git remote`); remote names
    /// may contain `/`, so the longest matching remote prefix is stripped. Refs
    /// under an unknown remote, remote `HEAD` symrefs, remote branches that
    /// already exist locally and names failing `GitShellQuoting.validate` are
    /// dropped.
    static func list(fromRefNames refs: [String], remotes: [String]) -> [GitBranchRef] {
        let remotesLongestFirst = remotes.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        var locals: [GitBranchRef] = []
        var remotes: [GitBranchRef] = []
        var localNames = Set<String>()
        for ref in refs where ref.hasPrefix("refs/heads/") {
            let name = String(ref.dropFirst("refs/heads/".count))
            guard GitShellQuoting.isSafe(name), localNames.insert(name).inserted else { continue }
            locals.append(GitBranchRef(name: name, switchName: name, isRemote: false))
        }
        var remoteSwitchNames = Set<String>()
        for ref in refs where ref.hasPrefix("refs/remotes/") {
            let name = String(ref.dropFirst("refs/remotes/".count))
            guard let remote = remotesLongestFirst.first(where: { name.hasPrefix($0 + "/") }) else { continue }
            let branch = String(name.dropFirst(remote.count + 1))
            guard !branch.isEmpty, branch != "HEAD", GitShellQuoting.isSafe(name), GitShellQuoting.isSafe(branch) else { continue }
            guard !localNames.contains(branch), remoteSwitchNames.insert(branch).inserted else { continue }
            remotes.append(GitBranchRef(name: name, switchName: branch, isRemote: true))
        }
        return locals + remotes
    }
}

extension GitStatusService {
    /// Local and remote branches for the popover. Read-only `for-each-ref`
    /// through the service's restricted runner, off the main thread.
    func branchRefs(root: URL) async -> [GitBranchRef] {
        guard let runner else { return [] }
        let timeout = Self.commandTimeout
        let (refsOutput, remotesOutput) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let refs = runner.run(
                    ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"],
                    in: root,
                    timeout: timeout
                )
                let remotes = runner.run(["remote"], in: root, timeout: timeout)
                continuation.resume(returning: (refs, remotes))
            }
        }
        guard refsOutput.succeeded else { return [] }
        let remotes = remotesOutput.succeeded ? remotesOutput.stdoutText.split(separator: "\n").map(String.init) : []
        return GitBranchRef.list(
            fromRefNames: refsOutput.stdoutText.split(separator: "\n").map(String.init),
            remotes: remotes
        )
    }
}

/// The popover behind the git chip.
///
/// Nothing here runs a mutating command. Choosing an action shows its exact
/// command line; "Insert" types it, "Run" types it and presses Enter. Both
/// need the shell at an empty primary prompt (`slimerIdlePrompt`); otherwise
/// Run is disabled and Insert becomes an explicit "Insert Anyway". The user's
/// input line is never cleared.
struct GitPopoverView: View {
    let state: GitRepoState
    let surfaceView: Ghostty.SurfaceView
    let dismiss: () -> Void

    @State private var branches: [GitBranchRef] = []
    @State private var branchesLoaded = false
    @State private var filter = ""
    @State private var newBranchName = ""
    @State private var pending: GitAction?
    @State private var pendingCommand: String?
    @State private var pendingError: String?
    @State private var idlePrompt = false
    @State private var sendError: String?
    @State private var gitHub: GitHubRemote?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let pending {
                confirmation(for: pending)
            } else {
                actions
                Divider()
                branchSection
                Divider()
                links
            }
        }
        .padding(12)
        .frame(width: 320)
        .task(id: state.root) {
            idlePrompt = surfaceView.slimerIdlePrompt
            async let refs = GitStatusService.shared.branchRefs(root: state.root)
            async let remote = GitStatusService.shared.gitHubRemote(root: state.root)
            branches = await refs
            gitHub = await remote
            branchesLoaded = true
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: state.isDetached ? "smallcircle.filled.circle" : "arrow.triangle.branch")
                Text(state.isDetached ? "Detached at \(displayHead)" : displayHead)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let operation = state.operation {
                    Text(StatusBarFormatting.operationBadge(operation))
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                }
            }
            Text(summary)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Branch names come from the repository (untrusted); display only.
    private var displayHead: String {
        SlimerUnsafeText.sanitizedForDisplay(state.headLabel)
    }

    private var summary: String {
        var parts: [String] = []
        if let upstream = state.upstream {
            parts.append("→ \(SlimerUnsafeText.sanitizedForDisplay(upstream)) ⇡\(state.ahead) ⇣\(state.behind)")
        } else if !state.isDetached {
            parts.append("no upstream")
        }
        parts.append("+\(state.staged) ~\(state.unstaged) ?\(state.untracked)")
        if state.conflicted > 0 { parts.append("!\(state.conflicted) conflicted") }
        if state.stashCount > 0 { parts.append("\(state.stashCount) stashed") }
        return parts.joined(separator: "  ·  ")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(GitActions.available(for: state)) { action in
                Button {
                    choose(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                TextField("New branch…", text: $newBranchName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createBranch)
                Button("Create", action: createBranch)
                    .disabled(!GitShellQuoting.isSafe(newBranchName))
            }
        }
    }

    private var branchSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredBranches) { branch in
                        branchRow(branch)
                    }
                    if branchesLoaded && filteredBranches.isEmpty {
                        Text("No branches").foregroundColor(.secondary)
                    } else if !branchesLoaded {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private func branchRow(_ branch: GitBranchRef) -> some View {
        let isCurrent = !branch.isRemote && branch.name == state.branch
        return Button {
            choose(GitActions.switchBranch(to: branch.switchName))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .opacity(isCurrent ? 1 : 0)
                Text(branch.name)
                    .foregroundColor(branch.isRemote ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    private var filteredBranches: [GitBranchRef] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let branch = state.branch, GitShellQuoting.isSafe(branch) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(branch, forType: .string)
                    dismiss()
                } label: {
                    Label("Copy Branch Name", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
            }
            if let gitHub {
                Button {
                    SlimerStatusBarActions.openGitHub(gitHub.repositoryURL)
                    dismiss()
                } label: {
                    Label("Open on GitHub", systemImage: "safari")
                }
                .buttonStyle(.plain)
                if let branch = state.branch, let prURL = gitHub.newPullRequestURL(branch: branch) {
                    Button {
                        SlimerStatusBarActions.openGitHub(prURL)
                        dismiss()
                    } label: {
                        Label("Open Pull Request", systemImage: "arrow.triangle.pull")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Confirmation

    private func confirmation(for action: GitAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(action.title).font(.subheadline.bold())
            if let pendingCommand {
                Text(pendingCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                if !idlePrompt {
                    Text(Self.notIdleExplanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let sendError {
                    Text(sendError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Cancel") { clearPending() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    // Return only ever inserts; running needs a click on "Run".
                    Button(idlePrompt ? "Insert" : "Insert Anyway") {
                        send(pendingCommand, run: false, confirmedWhileBusy: !idlePrompt)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Run") { send(pendingCommand, run: true, confirmedWhileBusy: false) }
                        .disabled(!idlePrompt)
                        .help(idlePrompt ? "Type the command and press Enter" : Self.runDisabledHelp)
                }
            } else {
                Text(pendingError ?? "This action is not available.")
                    .foregroundColor(.red)
                Button("Back") { clearPending() }
            }
        }
    }

    static let notIdleExplanation = """
        The terminal is not at an empty shell prompt (a program is running, \
        text is already typed, or shell integration is off). Run is disabled; \
        Insert Anyway types the command after whatever is there.
        """

    static let runDisabledHelp =
        "Run needs an empty shell prompt with shell integration; a program is running or text is already typed"

    private func choose(_ action: GitAction) {
        idlePrompt = surfaceView.slimerIdlePrompt
        sendError = nil
        pending = action
        do {
            pendingCommand = try action.commandLine(for: state)
            pendingError = nil
        } catch {
            pendingCommand = nil
            pendingError = "Refusing to build this command: the name is not safe to type into a shell."
        }
    }

    private func createBranch() {
        let name = newBranchName.trimmingCharacters(in: .whitespaces)
        guard GitShellQuoting.isSafe(name) else { return }
        choose(GitActions.createBranch(named: name))
    }

    private func clearPending() {
        pending = nil
        pendingCommand = nil
        pendingError = nil
        sendError = nil
    }

    private func send(_ command: String, run: Bool, confirmedWhileBusy: Bool) {
        switch SlimerTerminalInput.insert(command, into: surfaceView, run: run, confirmedWhileBusy: confirmedWhileBusy) {
        case .success(.type):
            dismiss()
            Ghostty.moveFocus(to: surfaceView)
        case .success(.needsConfirmation), .success(.refuseRun):
            // The prompt changed since the popover looked; show why and let the
            // user decide again.
            idlePrompt = false
            sendError = "The prompt is no longer empty. Nothing was typed."
        case .failure(.surfaceUnavailable):
            sendError = "This terminal is no longer available. Nothing was typed."
        case .failure:
            sendError = "Refusing to type this command: it contains characters that are not allowed."
        }
    }
}
