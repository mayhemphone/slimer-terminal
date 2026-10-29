import SwiftUI

/// General ▸ Shortcut Sheet: which modifier to hold and for how long.
struct ShortcutOverlaySettingsSection: View {
    @ObservedObject var store: SettingsConfigStore

    static let delayKey = "slimer-shortcut-overlay-delay"
    static let delayLabels: [String: String] = [
        "500ms": "0.5 seconds", "1s": "1 second", "1500ms": "1.5 seconds",
        "2s": "2 seconds", "3s": "3 seconds", "5s": "5 seconds",
    ]

    var body: some View {
        Section {
            ConfigPicker(store: store, title: "Hold to show shortcuts",
                         key: "slimer-shortcut-overlay",
                         labels: ["ctrl": "Control ⌃", "cmd": "Command ⌘", "option": "Option ⌥", "off": "Off"],
                         fallback: "ctrl")
            delayPicker
        } header: {
            Text("Shortcut Sheet")
        } footer: {
            Text("Hold the key on its own to see every shortcut. Pressing another key cancels it, so normal shortcuts never show the sheet.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    /// Like `ConfigPicker`, but keeps a value from the user's config that isn't one of
    /// the presets (e.g. `2500ms`) selectable instead of showing a blank picker.
    private var delayPicker: some View {
        let key = Self.delayKey
        let current = store.displayValue(for: key) ?? "2s"
        var values = SettingsKeySpec.allowedValues(for: key)
        if !values.contains(current) { values.append(current) }
        return VStack(alignment: .leading, spacing: 4) {
            Picker("After holding for", selection: Binding(
                get: { current },
                set: { store.set(key, $0) }
            )) {
                ForEach(values, id: \.self) { value in
                    Text(Self.delayLabels[value] ?? ShortcutCatalog.displayTitle(value)).tag(value)
                }
            }
            .disabled(store.isOverridden(key) || store.displayValue(for: "slimer-shortcut-overlay") == "off")
            ConfigKeyStatus(store: store, key: key)
        }
    }
}
