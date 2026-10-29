import AppKit
import SwiftUI

/// Theme, font, window background and chrome.
struct AppearancePane: View {
    @ObservedObject var store: SettingsConfigStore

    var body: some View {
        Form {
            ConfigFileBanner(store: store)

            Section("Theme") {
                ThemeNamePicker(store: store)
            }

            Section("Font") {
                FontFamilyField(store: store)
                FontSizeField(store: store)
            }

            Section("Window") {
                ConfigSlider(store: store, title: "Background opacity", key: "background-opacity",
                             range: 0...1, step: 0.05, fallback: 1,
                             format: { "\(Int(($0 * 100).rounded()))%" })
                BlurPicker(store: store)
                ConfigPicker(store: store, title: "Title bar", key: "macos-titlebar-style",
                             labels: ["native": "Native", "transparent": "Transparent",
                                      "tabs": "Tabs in title bar", "hidden": "Hidden"],
                             fallback: "transparent")
                Text("Title bar changes apply to new windows.").font(.caption).foregroundColor(.secondary)
                ConfigPicker(store: store, title: "Status bar", key: "slimer-status-bar",
                             labels: ["bottom": "Bottom", "top": "Top", "hidden": "Hidden"],
                             fallback: "bottom")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Theme

/// Lists Ghostty theme names from the user's and the app's themes directories (the same
/// places `ghostty +list-themes` and the theme resolver look), with a search field.
struct ThemeNamePicker: View {
    @ObservedObject var store: SettingsConfigStore
    @State private var names: [String] = []
    @State private var query = ""
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Current:")
                Text(store.displayValue(for: "theme") ?? "None (Ghostty default colors)")
                    .fontWeight(.medium)
                Spacer()
                if store.isManaged("theme") {
                    Button("Clear") { store.set("theme", nil) }
                }
            }
            TextField("Search themes", text: $query)
                .textFieldStyle(.roundedBorder)
            if loading {
                ProgressView().controlSize(.small)
            } else {
                List(filtered, id: \.self) { name in
                    Button {
                        store.set("theme", name)
                    } label: {
                        HStack {
                            Text(name)
                            Spacer()
                            if store.displayValue(for: "theme") == name {
                                Image(systemName: "checkmark")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 180)
            }
            ConfigKeyStatus(store: store, key: "theme")
        }
        .disabled(store.isOverridden("theme"))
        .task {
            let dirs = GhosttyThemeResolver.searchDirectories()
            names = await Task.detached(priority: .userInitiated) { Self.themeNames(in: dirs) }.value
            loading = false
        }
    }

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    /// Regular files with safe names, deduplicated, sorted case-insensitively.
    nonisolated static func themeNames(in directories: [URL]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for dir in directories {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in entries {
                let name = url.lastPathComponent
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      case .success = SettingsValidator.validateThemeValue(name),
                      seen.insert(name).inserted else { continue }
                result.append(name)
            }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Font

struct FontFamilyField: View {
    @ObservedObject var store: SettingsConfigStore
    @State private var text = ""
    @State private var families: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Font family", text: $text, prompt: Text("Ghostty default"))
                    .onSubmit(commit)
                Menu("Monospaced") {
                    ForEach(families, id: \.self) { family in
                        Button(family) {
                            text = family
                            commit()
                        }
                    }
                }
                .frame(width: 130)
                .disabled(families.isEmpty)
            }
            ConfigKeyStatus(store: store, key: "font-family")
        }
        .disabled(store.isOverridden("font-family"))
        .onAppear {
            text = store.displayValue(for: "font-family") ?? ""
        }
        .task {
            // Fixed-pitch families only; built once when the pane first appears.
            let manager = NSFontManager.shared
            families = manager.availableFontFamilies.filter { family in
                guard let members = manager.availableMembers(ofFontFamily: family),
                      let postScriptName = members.first?.first as? String,
                      let font = NSFont(name: postScriptName, size: 12) else { return false }
                return font.isFixedPitch
            }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        store.set("font-family", trimmed.isEmpty ? nil : trimmed)
    }
}

struct FontSizeField: View {
    @ObservedObject var store: SettingsConfigStore

    var body: some View {
        let value = Binding<Double>(
            get: { store.displayValue(for: "font-size").flatMap(SettingsValidator.parseNumber) ?? 13 },
            set: { store.set("font-size", SettingsValidator.format($0)) }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Font size")
                Spacer()
                TextField("Font size", value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .frame(width: 60)
                Stepper("Font size", value: value, in: 4...200, step: 0.5).labelsHidden()
            }
            ConfigKeyStatus(store: store, key: "font-size")
        }
        .disabled(store.isOverridden("font-size"))
    }
}

// MARK: - Blur

struct BlurPicker: View {
    @ObservedObject var store: SettingsConfigStore

    private static let presets: [(String, String)] = [
        ("false", "Off"), ("true", "On"), ("10", "Light (10)"), ("40", "Strong (40)"),
        ("macos-glass-regular", "Glass (macOS 26)"), ("macos-glass-clear", "Clear glass (macOS 26)"),
    ]

    var body: some View {
        let current = store.displayValue(for: "background-blur") ?? "false"
        VStack(alignment: .leading, spacing: 4) {
            Picker("Background blur", selection: Binding(
                get: { current == "20" ? "true" : current },
                set: { store.set("background-blur", $0) }
            )) {
                ForEach(Self.presets, id: \.0) { value, label in
                    Text(label).tag(value)
                }
                if !Self.presets.contains(where: { $0.0 == current }) && current != "20" {
                    Text("Radius \(current)").tag(current)
                }
            }
            .disabled(store.isOverridden("background-blur"))
            ConfigKeyStatus(store: store, key: "background-blur")
        }
    }
}
