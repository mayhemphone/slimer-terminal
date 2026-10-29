import AppKit
import SwiftUI

/// Slimer's per-terminal themes and the rules that pick them (`themes.json`).
struct ThemesPane: View {
    @ObservedObject private var store = ThemeStore.shared
    @State private var selectedThemeId: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                persistenceBanner

                GroupBox("Themes") {
                    HStack(alignment: .top, spacing: 12) {
                        themeList
                        Divider()
                        if let id = selectedThemeId, let theme = store.theme(id: id) {
                            ThemeEditor(theme: theme, editable: store.acceptsEdits) { updated in
                                store.upsert(updated)
                            }
                            .id(theme.id)
                        } else {
                            Text("Select a theme to edit it.")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minHeight: 280)
                }

                GroupBox("Rules") {
                    ThemeRulesEditor(store: store)
                }

                HStack {
                    Button("Open themes.json") { NSWorkspace.shared.open(store.fileURL) }
                    Button("Reload") { store.reload() }
                    Spacer()
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var persistenceBanner: some View {
        switch store.persistence {
        case .writable:
            EmptyView()
        case .unparseable:
            SettingsBanner(style: .warning, text: "themes.json isn't valid JSON. Showing presets; your first edit here moves the broken file aside (themes.json.broken-<time>) and saves a new one.")
        case .unreadable:
            SettingsBanner(style: .error, text: "themes.json can't be read (permissions, size, or not a regular file). Editing is disabled.")
        case .lossy:
            SettingsBanner(style: .warning, text: "themes.json has entries or keys this version doesn't understand (or comes from a newer Slimer). To avoid losing them, Settings won't edit it. Edit the file by hand instead.")
        }
    }

    private var themeList: some View {
        VStack(alignment: .leading, spacing: 6) {
            List(store.themes, selection: $selectedThemeId) { theme in
                HStack {
                    Circle()
                        .fill(Color(hex: theme.accent ?? theme.background) ?? .secondary)
                        .frame(width: 10, height: 10)
                    Text(theme.name.isEmpty ? "Untitled" : theme.name)
                }
                .tag(theme.id)
            }
            .frame(width: 200)
            HStack {
                Button {
                    let theme = SurfaceTheme(name: "New Theme", background: "#1E1E1E", foreground: "#DDDDDD")
                    store.upsert(theme)
                    selectedThemeId = theme.id
                } label: { Image(systemName: "plus") }
                Button {
                    guard let id = selectedThemeId else { return }
                    store.remove(themeId: id)
                    selectedThemeId = nil
                } label: { Image(systemName: "minus") }
                .disabled(selectedThemeId == nil)
                .help("Delete the theme and the rules that use it")
            }
            .buttonStyle(.borderless)
            .disabled(!store.acceptsEdits)
        }
    }
}

// MARK: - Theme editor

struct ThemeEditor: View {
    let editable: Bool
    let onSave: (SurfaceTheme) -> Void
    @State private var draft: SurfaceTheme

    init(theme: SurfaceTheme, editable: Bool, onSave: @escaping (SurfaceTheme) -> Void) {
        self.editable = editable
        self.onSave = onSave
        _draft = State(initialValue: theme)
    }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            TextField("Ghostty theme", text: Binding(
                get: { draft.ghosttyTheme ?? "" },
                set: { draft.ghosttyTheme = $0.isEmpty ? nil : $0 }
            ), prompt: Text("optional, e.g. Nord"))
            HexColorRow(title: "Background", hex: $draft.background)
            HexColorRow(title: "Foreground", hex: $draft.foreground)
            HexColorRow(title: "Cursor", hex: $draft.cursorColor)
            HexColorRow(title: "Selection", hex: $draft.selectionBackground)
            HexColorRow(title: "Tab accent", hex: $draft.accent)
            HStack {
                Spacer()
                Button("Save Theme") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .disabled(!editable)
    }

    private var isValid: Bool {
        let colors = [draft.background, draft.foreground, draft.cursorColor, draft.selectionBackground, draft.accent]
        return !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !SettingsValidator.containsLineBreakOrControl(draft.name)
            && colors.allSatisfy { $0 == nil || SurfaceTheme.isValidHex($0 ?? "") }
            && (draft.ghosttyTheme == nil || SurfaceTheme.sanitizedThemeName(draft.ghosttyTheme ?? "") != nil)
    }
}

/// An optional `#RRGGBB` color: a toggle, a color well and a strict hex field.
struct HexColorRow: View {
    let title: String
    @Binding var hex: String?
    @State private var text = ""

    var body: some View {
        HStack {
            Toggle(title, isOn: Binding(
                get: { hex != nil },
                set: { on in
                    hex = on ? (SurfaceTheme.validHex(text) ?? "#808080") : nil
                    text = hex ?? ""
                }
            ))
            .frame(width: 140, alignment: .leading)
            ColorPicker(title, selection: Binding(
                get: { Color(hex: hex) ?? .gray },
                set: { color in
                    guard let value = color.rgbHex else { return }
                    hex = value
                    text = value
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .disabled(hex == nil)
            TextField("#RRGGBB", text: $text)
                .frame(width: 90)
                .monospaced()
                .disabled(hex == nil)
                .onSubmit(commitText)
                .onChange(of: text) { _ in commitText() }
            if hex != nil && !SurfaceTheme.isValidHex(text) {
                Text("Use #RRGGBB").font(.caption).foregroundColor(.red)
            }
        }
        .onAppear { text = hex ?? "" }
    }

    private func commitText() {
        // Strict: only an exact #RRGGBB updates the color.
        guard hex != nil, SurfaceTheme.isValidHex(text) else { return }
        hex = text.uppercased()
    }
}

// MARK: - Rules

struct ThemeRulesEditor: View {
    @ObservedObject var store: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Kind").frame(width: 110, alignment: .leading)
                Text("Value").frame(maxWidth: .infinity, alignment: .leading)
                Text("Theme").frame(width: 150, alignment: .leading)
                Text("Priority").frame(width: 90, alignment: .leading)
                Spacer().frame(width: 24)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            List {
                ForEach(store.rules) { rule in
                    ThemeRuleRow(rule: rule, themes: store.themes, editable: store.acceptsEdits) { updated in
                        store.update(rule: updated)
                    } onDelete: {
                        store.remove(ruleId: rule.id)
                    }
                }
                .onMove { source, destination in
                    guard store.acceptsEdits else { return }
                    store.moveRules(fromOffsets: source, toOffset: destination)
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button("Add Rule") {
                    guard let theme = store.themes.first else { return }
                    store.add(rule: ThemeRule(match: .pathPrefix("~/"), themeId: theme.id))
                }
                .disabled(!store.acceptsEdits || store.themes.isEmpty)
                Spacer()
                Text("Drag to reorder. Higher priority wins; ties go to the most specific match, then the earliest rule.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct ThemeRuleRow: View {
    let rule: ThemeRule
    let themes: [SurfaceTheme]
    let editable: Bool
    let onChange: (ThemeRule) -> Void
    let onDelete: () -> Void

    @State private var value = ""

    var body: some View {
        HStack {
            Picker("Kind", selection: Binding(
                get: { rule.match.kind },
                set: { kind in commit(kind: kind, value: rule.match.value) }
            )) {
                Text("Folder").tag("pathPrefix")
                Text("Host").tag("hostname")
                Text("Command").tag("command")
            }
            .labelsHidden()
            .frame(width: 110)

            TextField("Value", text: $value)
                .onSubmit { commit(kind: rule.match.kind, value: value) }
                .frame(maxWidth: .infinity)

            Picker("Theme", selection: Binding(
                get: { rule.themeId },
                set: { id in
                    var copy = rule
                    copy.themeId = id
                    onChange(copy)
                }
            )) {
                ForEach(themes) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Stepper(value: Binding(
                get: { rule.priority },
                set: { priority in
                    var copy = rule
                    copy.priority = priority
                    onChange(copy)
                }
            ), in: -100...100) {
                Text("\(rule.priority)").monospacedDigit()
            }
            .frame(width: 90)

            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .frame(width: 24)
        }
        .disabled(!editable)
        .onAppear { value = rule.match.value }
        .onChange(of: rule.match.value) { value = $0 }
    }

    private func commit(kind: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !SettingsValidator.containsLineBreakOrControl(trimmed) else {
            self.value = rule.match.value
            return
        }
        let match: ThemeRule.Match
        switch kind {
        case "hostname": match = .hostname(trimmed)
        case "command": match = .command(trimmed)
        default: match = .pathPrefix(trimmed)
        }
        var copy = rule
        copy.match = match
        onChange(copy)
    }
}

// MARK: - Color helpers

extension Color {
    /// A color from a strict `#RRGGBB` string, or nil.
    init?(hex: String?) {
        guard let hex, SurfaceTheme.isValidHex(hex), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// `#RRGGBB` in sRGB, or nil when the color can't be converted.
    var rgbHex: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func byte(_ c: CGFloat) -> Int { Int((min(max(c, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
