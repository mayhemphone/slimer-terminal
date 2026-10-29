import AppKit
import SwiftUI

/// Files, reload, Slimer's managed block and Ghostty's diagnostics.
struct AdvancedPane: View {
    @ObservedObject var store: SettingsConfigStore
    @StateObject private var diagnostics = DiagnosticsModel()

    var body: some View {
        Form {
            ConfigFileBanner(store: store)

            Section("Ghostty Config") {
                LabeledContent("File") {
                    Text(store.file?.url.path ?? "Unknown").textSelection(.enabled)
                }
                if let file = store.file, file.targetURL.path != file.url.standardizedFileURL.path {
                    LabeledContent("Symlink target") {
                        Text(file.targetURL.path).textSelection(.enabled)
                    }
                }
                if let backup = store.file?.backups().last {
                    LabeledContent("Latest backup") {
                        Text(backup.path).textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Open Config File") { appDelegate?.ghostty.openConfig() }
                    Button("Reveal in Finder") {
                        guard let url = store.file?.targetURL else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    Button("Reload Config") {
                        store.flush()
                        appDelegate?.ghostty.reloadConfig()
                        store.load()
                    }
                }
            }

            Section {
                let lines = store.entries().flatMap { entry in entry.values.map { "\(entry.key) = \($0)" } }
                if lines.isEmpty {
                    Text("Settings hasn't changed any Ghostty keys yet.").foregroundColor(.secondary)
                } else {
                    Text(([GhosttyConfigWriter.beginMarker] + lines + [GhosttyConfigWriter.endMarker]).joined(separator: "\n"))
                        .font(.system(size: 11).monospaced())
                        .textSelection(.enabled)
                }
                ForEach(store.findings.filter { $0.kind == .include }) { finding in
                    FindingLabel(finding: finding).font(.caption)
                }
            } header: {
                Text("Slimer's Block")
            } footer: {
                Text("Settings only edits the lines between these markers. Everything else in the file is yours.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Diagnostics") {
                if diagnostics.errors.isEmpty {
                    Label("Ghostty loaded the config without errors.", systemImage: "checkmark.circle")
                        .foregroundColor(.secondary)
                } else {
                    ConfigurationErrorsView(model: diagnostics)
                        .frame(minHeight: 270)
                }
            }

            Section("Slimer Data") {
                HStack {
                    Button("Open workspace.json") { WorkspaceStore.shared.openInEditor() }
                    Button("Open themes.json") { NSWorkspace.shared.open(ThemeStore.shared.fileURL) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { diagnostics.errors = store.diagnostics }
        .onChange(of: store.diagnostics) { diagnostics.errors = $0 }
    }

    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }
}

/// Adapts the store's diagnostics to `ConfigurationErrorsView`'s model. "Ignore" only
/// hides them here; the next load shows them again.
final class DiagnosticsModel: ConfigurationErrorsViewModel {
    @Published var errors: [String] = []
}
