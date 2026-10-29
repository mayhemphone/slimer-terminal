import SwiftUI

// Reusable rows bound to `SettingsConfigStore`. Every control writes through
// `SettingsConfigStore.set(_:_:)`, which validates before anything is scheduled.

/// Status lines under a config-backed control: validation error, "didn't apply" badge,
/// notes about the user's own lines, and a button to hand the key back to the user.
struct ConfigKeyStatus: View {
    @ObservedObject var store: SettingsConfigStore
    let key: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = store.fieldErrors[key] {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red)
            }
            if let effective = store.notApplied[key] {
                Label("Ghostty didn't apply this; it is using “\(effective)”. See Advanced ▸ Diagnostics.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            ForEach(store.findings(for: key)) { finding in
                FindingLabel(finding: finding)
            }
            if store.isManaged(key) {
                Button("Use value from my config") { store.set(key, nil) }
                    .buttonStyle(.link)
                    .help("Remove \(key) from Slimer's block so your own config line (or Ghostty's default) applies.")
            }
        }
        .font(.caption)
    }
}

struct FindingLabel: View {
    let finding: GhosttyConfigWriter.Finding

    var body: some View {
        switch finding.kind {
        case .overriddenAfter:
            Label(finding.message, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .addsAfter, .include:
            Label(finding.message, systemImage: "info.circle").foregroundColor(.secondary)
        case .setBefore:
            Label(finding.message, systemImage: "info.circle").foregroundColor(.secondary)
        }
    }
}

/// A picker over an enumeration key's allowed values.
struct ConfigPicker: View {
    @ObservedObject var store: SettingsConfigStore
    let title: String
    let key: String
    var labels: [String: String] = [:]
    var fallback: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: Binding(
                get: { store.displayValue(for: key) ?? fallback },
                set: { store.set(key, $0) }
            )) {
                ForEach(SettingsKeySpec.allowedValues(for: key), id: \.self) { value in
                    Text(labels[value] ?? value).tag(value)
                }
            }
            .disabled(store.isOverridden(key))
            ConfigKeyStatus(store: store, key: key)
        }
    }
}

/// A toggle for a boolean key.
struct ConfigToggle: View {
    @ObservedObject var store: SettingsConfigStore
    let title: String
    let key: String
    var fallback: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(
                get: { (store.displayValue(for: key)).map { $0 == "true" } ?? fallback },
                set: { store.set(key, $0 ? "true" : "false") }
            ))
            .disabled(store.isOverridden(key))
            ConfigKeyStatus(store: store, key: key)
        }
    }
}

/// A slider for a numeric key. The store debounces writes, so dragging is cheap.
struct ConfigSlider: View {
    @ObservedObject var store: SettingsConfigStore
    let title: String
    let key: String
    let range: ClosedRange<Double>
    var step: Double
    var fallback: Double
    var format: (Double) -> String = { SettingsValidator.format($0) }

    var body: some View {
        let value = Binding<Double>(
            get: { store.displayValue(for: key).flatMap(SettingsValidator.parseNumber) ?? fallback },
            set: { newValue in
                // Snap to the step so the written value is short and stable.
                let snapped = (newValue / step).rounded() * step
                store.set(key, SettingsValidator.format(min(max(snapped, range.lowerBound), range.upperBound)))
            }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Slider(value: value, in: range, step: step)
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .disabled(store.isOverridden(key))
            ConfigKeyStatus(store: store, key: key)
        }
    }
}

/// A text field committed on Enter or focus loss, validated by the store.
struct ConfigTextField: View {
    @ObservedObject var store: SettingsConfigStore
    let title: String
    let key: String
    var prompt: String = ""

    @State private var text: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text, prompt: Text(prompt))
                .onSubmit(commit)
                .disabled(store.isOverridden(key))
                .onAppear {
                    guard !loaded else { return }
                    loaded = true
                    text = store.displayValue(for: key) ?? ""
                }
            ConfigKeyStatus(store: store, key: key)
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        store.set(key, trimmed.isEmpty ? nil : trimmed)
    }
}

/// A banner shown at the top of a pane.
struct SettingsBanner: View {
    enum Style { case warning, error, info }
    let style: Style
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
    }

    private var icon: String {
        switch style {
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch style {
        case .warning: return .orange
        case .error: return .red
        case .info: return .accentColor
        }
    }
}

/// Shows the config file error, if any, at the top of config-backed panes.
struct ConfigFileBanner: View {
    @ObservedObject var store: SettingsConfigStore

    var body: some View {
        if let error = store.fileError {
            SettingsBanner(style: .error, text: error)
        }
    }
}
