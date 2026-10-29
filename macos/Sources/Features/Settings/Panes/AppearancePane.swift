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
///
/// Clicking a name, or moving with the arrow keys once the list has focus, sets `theme`
/// right away in Settings; the store debounces the config write (and so the reload) until
/// you pause.
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
                // An AppKit table in its own NSScrollView, not a SwiftUI List: a List nested
                // in a grouped Form (itself a scroll view) gets no wheel events and no
                // scroller on macOS 13/14.
                ThemeNameTable(
                    names: filtered,
                    selected: store.displayValue(for: "theme"),
                    enabled: !store.isOverridden("theme")
                ) { name in
                    store.set("theme", name)
                }
                .frame(height: 220)
                Text("Click a theme, then use ↑ and ↓ to try others. Saved when you pause.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    /// Regular files with plain names, deduplicated, sorted case-insensitively. The same
    /// list the per-terminal Theme Browser shows.
    nonisolated static func themeNames(in directories: [URL]) -> [String] {
        GhosttyThemeResolver.themeNames(in: directories)
    }
}

/// A single-column `NSTableView` in a bordered `NSScrollView` with an always-visible
/// scroller. Arrow keys move the selection natively; every selection change made by the
/// user calls `onSelect`. Selection changes coming from `selected` don't.
struct ThemeNameTable: NSViewRepresentable {
    let names: [String]
    let selected: String?
    var enabled = true
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 20
        table.allowsEmptySelection = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        // Always show the scroller; overlay scrollers stay hidden until you scroll.
        scroll.scrollerStyle = .legacy
        scroll.borderType = .bezelBorder
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.table?.isEnabled = enabled
        if coordinator.names != names {
            coordinator.reload(names: names, selected: selected)
        } else if coordinator.selected != selected {
            // Scroll only when the value changed elsewhere, not for the user's own moves.
            coordinator.syncSelection(selected, scroll: !coordinator.userSelected(selected))
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        var names: [String] = []
        var selected: String?
        var onSelect: (String) -> Void = { _ in }
        private var syncing = false
        private var lastUserSelection: String?

        private static let cellIdentifier = NSUserInterfaceItemIdentifier("ThemeNameCell")

        func userSelected(_ name: String?) -> Bool {
            name != nil && name == lastUserSelection
        }

        /// New rows (the search changed). reloadData can trim the old selection and notify;
        /// that must never be taken as the user picking a theme.
        func reload(names newNames: [String], selected name: String?) {
            names = newNames
            syncing = true
            table?.reloadData()
            syncing = false
            syncSelection(name, scroll: true)
        }

        func syncSelection(_ name: String?, scroll: Bool) {
            selected = name
            guard let table else { return }
            syncing = true
            defer { syncing = false }
            if let name, let row = names.firstIndex(of: name) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if scroll { table.scrollRowToVisible(row) }
            } else {
                table.deselectAll(nil)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { names.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard names.indices.contains(row) else { return nil }
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = Self.cellIdentifier
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingTail
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            cell.textField?.stringValue = names[row]
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            let row = table.selectedRow
            guard names.indices.contains(row) else { return }
            let name = names[row]
            lastUserSelection = name
            selected = name
            onSelect(name)
        }
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
