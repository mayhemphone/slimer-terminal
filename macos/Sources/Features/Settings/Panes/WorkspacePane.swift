import AppKit
import SwiftUI

/// Locations, saved commands and recent directories from `workspace.json`.
struct WorkspacePane: View {
    enum Section: String, CaseIterable, Identifiable {
        case locations = "Locations"
        case commands = "Commands"
        case recent = "Recent"
        var id: String { rawValue }
    }

    @ObservedObject private var store = WorkspaceStore.shared
    @State private var section: Section = .locations

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = store.loadError {
                SettingsBanner(style: .error, text: "workspace.json can't be read, so editing is disabled until it is fixed: \(error)")
            }
            Picker("Show", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch section {
            case .locations: LocationsEditor(store: store)
            case .commands: CommandsEditor(store: store)
            case .recent: RecentEditor(store: store)
            }

            HStack {
                Button("Open workspace.json") { store.openInEditor() }
                Button("Reload") { store.reload() }
                Spacer()
            }
        }
        .padding(20)
    }
}

// MARK: - Shortcut policy

enum WorkspaceShortcutCheck {
    /// Any live surface, to ask libghostty about keybindings (app-wide config).
    @MainActor
    static var bindingSurface: Ghostty.Surface? {
        TerminalController.preferredParent?.focusedSurface?.surfaceModel
            ?? TerminalController.all.lazy.compactMap { $0.focusedSurface?.surfaceModel }.first
    }

    /// The Workspace shortcut policy (must include ⌘, must not be a Ghostty keybinding),
    /// plus "not already used by another workspace item".
    @MainActor
    static func error(for trigger: String, excluding id: UUID, in document: WorkspaceDocument) -> String? {
        guard KeyTrigger.isValidWorkspaceShortcut(trigger) else {
            return "Workspace shortcuts must include ⌘."
        }
        let surface = bindingSurface
        guard let shortcut = WorkspaceShortcut.accepted(trigger, log: false, isBound: { shortcut in
            guard let surface else { return false }
            return WorkspaceShortcut.isGhosttyBinding(shortcut, on: surface)
        }) else {
            return "\(KeyTrigger.displayString(trigger)) is already a Ghostty keybinding."
        }
        let others = document.locations.filter { $0.id != id }.compactMap(\.shortcut)
            + document.commands.filter { $0.id != id }.compactMap(\.shortcut)
        if others.compactMap(WorkspaceShortcut.init(parsing:)).contains(shortcut) {
            return "\(KeyTrigger.displayString(trigger)) is already used by another location or command."
        }
        return nil
    }
}

private func isCleanText(_ text: String) -> Bool {
    !SettingsValidator.containsLineBreakOrControl(text)
}

// MARK: - Locations

struct LocationsEditor: View {
    @ObservedObject var store: WorkspaceStore
    @State private var selection: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selection) {
                    ForEach(store.document.visibleLocations) { location in
                        Label {
                            Text(location.name)
                        } icon: {
                            Image(systemName: location.icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil ? nil : $0 } ?? "folder")
                                .foregroundColor(Color(hex: location.color) ?? .secondary)
                        }
                        .tag(location.id)
                    }
                    .onMove { source, destination in
                        store.edit { $0.moveVisibleLocations(fromOffsets: source, toOffset: destination) }
                    }
                }
                .frame(width: 220)
                HStack {
                    Button {
                        let location = WorkspaceLocation(name: "New Location", path: "~")
                        store.edit { $0.locations.append(location) }
                        selection = location.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let id = selection else { return }
                        store.edit { $0.locations.removeAll { $0.id == id } }
                        selection = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                }
                .buttonStyle(.borderless)
            }
            Divider()
            if let id = selection, let location = store.document.locations.first(where: { $0.id == id }) {
                LocationForm(location: location, document: store.document) { updated in
                    store.edit { doc in
                        guard let idx = doc.locations.firstIndex(where: { $0.id == updated.id }) else { return }
                        // Only the edited fields; other OS paths and unknown keys stay as in the
                        // (possibly newer) document.
                        doc.locations[idx].applyEdits(from: updated)
                    }
                }
                .id(location.id)
            } else {
                Text("Select a location to edit it. Drag to reorder.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .disabled(!store.acceptsEdits)
    }
}

struct LocationForm: View {
    let document: WorkspaceDocument
    let onSave: (WorkspaceLocation) -> Void
    @State private var draft: WorkspaceLocation
    @State private var shortcutError: String?

    init(location: WorkspaceLocation, document: WorkspaceDocument, onSave: @escaping (WorkspaceLocation) -> Void) {
        self.document = document
        self.onSave = onSave
        _draft = State(initialValue: location)
    }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            HStack {
                TextField("Path", text: $draft.editablePath)
                Button("Choose…", action: chooseFolder)
            }
            if !pathIsValid {
                Text("The path must be absolute (or start with ~/).").font(.caption).foregroundColor(.red)
            }
            HStack {
                TextField("Icon (SF Symbol)", text: Binding(
                    get: { draft.icon ?? "" },
                    set: { draft.icon = $0.isEmpty ? nil : $0 }
                ), prompt: Text("folder"))
                if let icon = draft.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                    Image(systemName: icon)
                }
            }
            HexColorRow(title: "Color", hex: $draft.color)
            Toggle("Pinned", isOn: $draft.pinned)
            LabeledContent("Shortcut") {
                KeyRecorderView(
                    trigger: draft.shortcut.flatMap(canonicalTrigger),
                    onChange: { draft.shortcut = $0 },
                    validate: { WorkspaceShortcutCheck.error(for: $0, excluding: draft.id, in: document) }
                )
            }
            TextField("Startup command", text: Binding(
                get: { draft.startupCommand ?? "" },
                set: { draft.startupCommand = $0.isEmpty ? nil : $0 }
            ), prompt: Text("optional, typed into new tabs"))
            if let cmd = draft.startupCommand, !WorkspaceShell.isSafeToInsert(cmd) {
                Text("The startup command contains control or invisible characters.").font(.caption).foregroundColor(.red)
            }
            Toggle("Wait for me to press Return", isOn: $draft.startupConfirm)
                .disabled(draft.startupCommand == nil)
            HStack {
                Spacer()
                Button("Save Location") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
    }

    private var pathIsValid: Bool {
        let expanded = WorkspacePath.expand(draft.editablePath.trimmingCharacters(in: .whitespaces))
        return expanded.hasPrefix("/") && isCleanText(draft.editablePath)
    }

    private var isValid: Bool {
        pathIsValid
            && !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && isCleanText(draft.name)
            && (draft.icon.map(isCleanText) ?? true)
            && (draft.color.map(SurfaceTheme.isValidHex) ?? true)
            && (draft.startupCommand.map(WorkspaceShell.isSafeToInsert) ?? true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: WorkspacePath.expand(draft.editablePath))
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.editablePath = WorkspacePath.abbreviate(url.path)
        if draft.name == "New Location" { draft.name = url.lastPathComponent }
    }
}

/// Shows stored shortcuts in the recorder's canonical form when they parse.
private func canonicalTrigger(_ shortcut: String) -> String? {
    guard let parsed = KeybindValue(parsing: "\(shortcut)=x") else { return shortcut }
    return parsed.normalizedTrigger
}

// MARK: - Commands

struct CommandsEditor: View {
    @ObservedObject var store: WorkspaceStore
    @State private var selection: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                List(selection: $selection) {
                    ForEach(store.document.visibleCommands) { command in
                        HStack {
                            Text(command.name)
                            Spacer()
                            if !command.confirm {
                                Text("⏎").foregroundColor(.secondary).help("Runs without waiting for Return")
                            }
                        }
                        .tag(command.id)
                    }
                    .onMove { source, destination in
                        store.edit { $0.moveVisibleCommands(fromOffsets: source, toOffset: destination) }
                    }
                }
                .frame(width: 220)
                HStack {
                    Button {
                        let command = WorkspaceCommand(name: "New Command", command: "echo hello")
                        store.edit { $0.commands.append(command) }
                        selection = command.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let id = selection else { return }
                        store.edit { $0.commands.removeAll { $0.id == id } }
                        selection = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                }
                .buttonStyle(.borderless)
            }
            Divider()
            if let id = selection, let command = store.document.commands.first(where: { $0.id == id }) {
                CommandForm(command: command, document: store.document) { updated in
                    store.edit { doc in
                        guard let idx = doc.commands.firstIndex(where: { $0.id == updated.id }) else { return }
                        doc.commands[idx].applyEdits(from: updated)
                    }
                }
                .id(command.id)
            } else {
                Text("Select a command to edit it. Drag to reorder.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .disabled(!store.acceptsEdits)
    }
}

struct CommandForm: View {
    let document: WorkspaceDocument
    let onSave: (WorkspaceCommand) -> Void
    @State private var draft: WorkspaceCommand

    init(command: WorkspaceCommand, document: WorkspaceDocument, onSave: @escaping (WorkspaceCommand) -> Void) {
        self.document = document
        self.onSave = onSave
        _draft = State(initialValue: command)
    }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            TextField("Command", text: $draft.command)
                .monospaced()
            if !WorkspaceShell.isSafeToInsert(draft.command) {
                Text("The command contains control or invisible characters.").font(.caption).foregroundColor(.red)
            }
            TextField("Run in", text: Binding(
                get: { draft.editableCwd ?? "" },
                set: { draft.editableCwd = $0.isEmpty ? nil : $0 }
            ), prompt: Text("optional directory"))
            Toggle("Pinned", isOn: $draft.pinned)
            LabeledContent("Shortcut") {
                KeyRecorderView(
                    trigger: draft.shortcut.flatMap(canonicalTrigger),
                    onChange: { draft.shortcut = $0 },
                    validate: { WorkspaceShortcutCheck.error(for: $0, excluding: draft.id, in: document) }
                )
            }
            Toggle("Wait for me to press Return", isOn: $draft.confirm)
            if !draft.confirm {
                Text("The command will run as soon as it is chosen.").font(.caption).foregroundColor(.orange)
            }
            HStack {
                Spacer()
                Button("Save Command") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
    }

    private var isValid: Bool {
        let command = draft.command.trimmingCharacters(in: .whitespaces)
        return !command.isEmpty
            && WorkspaceShell.isSafeToInsert(draft.command)
            && !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && isCleanText(draft.name)
            && (draft.editableCwd.map { isCleanText($0) && WorkspacePath.expand($0).hasPrefix("/") } ?? true)
    }
}

// MARK: - Recent

struct RecentEditor: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List {
                ForEach(store.rankedRecent(), id: \.path) { recent in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(WorkspacePath.abbreviate(recent.path))
                            Text("\(recent.count) visits · \(recent.lastVisited.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isLocation(recent.path) {
                            Text("Location").font(.caption).foregroundColor(.secondary)
                        } else {
                            Button("Promote to Location") { promote(recent) }
                                .disabled(!store.acceptsEdits)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                // Recent directories are per machine (recent.json), so clearing works even
                // when workspace.json can't be edited.
                Button("Clear Recent") { store.clearRecent() }
                    .disabled(store.recent.recent.isEmpty)
            }
        }
    }

    private func isLocation(_ path: String) -> Bool {
        store.document.visibleLocations.contains { $0.expandedPath == path }
    }

    private func promote(_ recent: WorkspaceRecentDirectory) {
        let location = WorkspaceLocation(
            name: WorkspacePath.displayName(for: recent.path),
            path: WorkspacePath.abbreviate(recent.path)
        )
        store.edit { doc in
            guard !doc.locations.contains(where: { $0.expandedPath == recent.path }) else { return }
            doc.locations.append(location)
        }
    }
}
