import SwiftUI

/// Claude Code launcher: detected binary and the default open mode.
struct ClaudePane: View {
    @AppStorage(ClaudeLauncher.defaultPlacementKey) private var placement = ClaudeLauncher.Placement.tab.rawValue
    @State private var binary: URL?

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Binary") {
                    Text(binary?.path ?? "Not found")
                        .textSelection(.enabled)
                        .foregroundColor(binary == nil ? .orange : .primary)
                }
                if binary == nil {
                    HStack {
                        Text("Slimer checks ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, ~/.claude/local and the app's PATH.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Install Claude Code…") { ClaudeLauncher.openInstallPage() }
                        Button("Check Again") { binary = ClaudeLauncher.binary }
                    }
                }
            }

            Section {
                Picker("Status bar button opens", selection: $placement) {
                    Text("New tab").tag(ClaudeLauncher.Placement.tab.rawValue)
                    Text("Split to the right").tag(ClaudeLauncher.Placement.splitRight.rawValue)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Default Open Mode")
            } footer: {
                Text("Option-click the button for the other mode. Continue and Resume always open a new tab.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { binary = ClaudeLauncher.binary }
    }
}
