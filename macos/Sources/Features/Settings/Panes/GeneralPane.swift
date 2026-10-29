import AppKit
import ApplicationServices
import SwiftUI

/// Global hotkeys, Accessibility permission, and window behavior.
struct GeneralPane: View {
    @ObservedObject var store: SettingsConfigStore
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            ConfigFileBanner(store: store)

            Section {
                ForEach(ManagedGlobalAction.allCases) { action in
                    hotkeyRow(action)
                }
                if let error = store.fieldErrors["keybind"] {
                    Text(error).font(.caption).foregroundColor(.red)
                }
                ForEach(store.findings(for: "keybind")) { finding in
                    FindingLabel(finding: finding).font(.caption)
                }
                if let note = store.includeNote(for: "keybind") {
                    Label(note.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                ForEach(store.leftActiveBindings, id: \.location) { binding in
                    Label(
                        "\(binding.location) still binds \(KeyTrigger.displayString(binding.trigger)) to \(binding.action.title.lowercased()); Settings can't remove it.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            } header: {
                Text("Global Hotkeys")
            } footer: {
                Text("Global hotkeys work in every app. They are written as `keybind = global:…` lines.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Accessibility") {
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(trusted ? .green : .orange)
                    Text(trusted
                         ? "Slimer has Accessibility access, so global hotkeys work."
                         : "Global hotkeys need Accessibility access.")
                    Spacer()
                    Button("Open System Settings…", action: openAccessibilitySettings)
                    Button {
                        trusted = AXIsProcessTrusted()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Check again")
                }
            }

            Section("Windows") {
                ConfigToggle(store: store, title: "New windows and tabs inherit the working directory",
                             key: "window-inherit-working-directory", fallback: true)
                ConfigPicker(store: store, title: "Confirm before closing a terminal",
                             key: "confirm-close-surface",
                             labels: ["true": "When a process is running", "false": "Never", "always": "Always"],
                             fallback: "true")
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            trusted = AXIsProcessTrusted()
        }
    }

    @ViewBuilder
    private func hotkeyRow(_ action: ManagedGlobalAction) -> some View {
        let current = store.effectiveTrigger(for: action)
        HStack {
            Text(action.title)
            Spacer()
            if let line = current.fromUserLine {
                Text("from your config, line \(line)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            KeyRecorderView(
                trigger: current.trigger,
                onChange: { trigger in
                    if let trigger {
                        store.setGlobalKeybind(action, .set(trigger))
                    } else {
                        // Clearing a hotkey that only Settings set just stops managing it;
                        // clearing one from the user's config disables it via the block.
                        let hasUserBinding = store.userGlobalBindings.contains { $0.action == action }
                        store.setGlobalKeybind(action, hasUserBinding ? .disabled : .unmanaged)
                    }
                },
                placeholder: "None",
                validate: { KeyTrigger.globalHotkeyError($0) }
            )
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
