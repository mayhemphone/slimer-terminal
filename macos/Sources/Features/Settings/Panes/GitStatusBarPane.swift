import SwiftUI

/// Status bar position plus read-only facts about the git integration.
struct GitStatusBarPane: View {
    @ObservedObject var store: SettingsConfigStore
    @ObservedObject private var git = GitStatusService.shared
    @State private var version: String?
    @State private var checkingVersion = true

    var body: some View {
        Form {
            ConfigFileBanner(store: store)

            Section("Status Bar") {
                ConfigPicker(store: store, title: "Position", key: "slimer-status-bar",
                             labels: ["bottom": "Bottom", "top": "Top", "hidden": "Hidden"],
                             fallback: "bottom")
            }

            Section("Git") {
                LabeledContent("Binary") {
                    Text(git.runner?.gitURL.path ?? "Not found")
                        .textSelection(.enabled)
                        .foregroundColor(git.runner == nil ? .orange : .primary)
                }
                LabeledContent("Version") {
                    if checkingVersion {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(version ?? "Unknown").textSelection(.enabled)
                    }
                }
                if git.runner == nil {
                    Text("Slimer looks for git only in \(GitProcessRunner.searchPath.joined(separator: ", ")). Install the Xcode command line tools or Homebrew git to enable the git chip.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section {
                let roots = git.states.keys.sorted { $0.path < $1.path }
                if roots.isEmpty {
                    Text("No repositories are being watched right now.").foregroundColor(.secondary)
                } else {
                    ForEach(roots, id: \.self) { root in
                        LabeledContent(WorkspacePath.abbreviate(root.path)) {
                            Text(git.lastRefreshDuration(root: root).map(Self.formatDuration) ?? "—")
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Last Refresh")
            } footer: {
                Text("Time for the most recent `git status` refresh of each open repository.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await loadVersion() }
    }

    private func loadVersion() async {
        guard let runner = git.runner else {
            checkingVersion = false
            return
        }
        // Read-only, bounded by the runner's timeout, off the main thread.
        let output = await Task.detached(priority: .utility) {
            runner.run(["--version"], in: nil)
        }.value
        let text = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        version = output.succeeded && !text.isEmpty ? String(text.prefix(80)) : nil
        checkingVersion = false
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: "%.2f s", seconds)
    }
}
