import AppKit
import SwiftUI

/// The quick terminal ("drawer"): position, size, screen, animation, tab bar.
struct DrawerPane: View {
    @ObservedObject var store: SettingsConfigStore

    var body: some View {
        Form {
            ConfigFileBanner(store: store)

            Section("Position") {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading) {
                        ConfigPicker(store: store, title: "Edge", key: "quick-terminal-position",
                                     labels: ["top": "Top", "bottom": "Bottom", "left": "Left",
                                              "right": "Right", "center": "Center"],
                                     fallback: "top")
                        ConfigPicker(store: store, title: "Screen", key: "quick-terminal-screen",
                                     labels: ["main": "Screen with keyboard focus", "mouse": "Screen with the mouse",
                                              "macos-menu-bar": "Screen with the menu bar"],
                                     fallback: "main")
                    }
                    DrawerSchematic(position: position, size: size)
                        .frame(width: 180, height: 116)
                        .accessibilityLabel(Text("Drawer position preview"))
                }
            }

            Section {
                QuickTerminalSizeEditor(store: store)
            } header: {
                Text("Size")
            } footer: {
                Text("Primary is the height for top/bottom drawers and the width for left/right. Secondary is the other axis; leave it off to fill the screen.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("Animation") {
                ConfigPicker(store: store, title: "Style", key: "quick-terminal-animation",
                             labels: ["slide": "Slide", "fade": "Fade", "none": "None"], fallback: "slide")
                ConfigPicker(store: store, title: "Easing", key: "quick-terminal-animation-easing",
                             labels: ["ease-in": "Ease in", "ease-out": "Ease out",
                                      "ease-in-out": "Ease in and out", "linear": "Linear"],
                             fallback: "ease-in")
                ConfigSlider(store: store, title: "Duration", key: "quick-terminal-animation-duration",
                             range: 0...1, step: 0.05, fallback: 0.2,
                             format: { String(format: "%.2fs", $0) })
            }

            Section("Behavior") {
                ConfigToggle(store: store, title: "Hide when another app is focused",
                             key: "quick-terminal-autohide", fallback: true)
                ConfigPicker(store: store, title: "Tab bar", key: "quick-terminal-tab-bar",
                             labels: ["auto": "With two or more tabs", "always": "Always", "never": "Never"],
                             fallback: "auto")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Preview Drawer") {
                        // Apply pending edits first so the preview shows them.
                        store.flush()
                        (NSApp.delegate as? AppDelegate)?.toggleQuickTerminal(self)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var position: String { store.displayValue(for: "quick-terminal-position") ?? "top" }

    /// Primary-axis size as a fraction of the screen (pixels assume a 1440×900 screen).
    private var size: (primary: Double, secondary: Double?) {
        let parts = (store.displayValue(for: "quick-terminal-size") ?? "")
            .split(separator: ",")
            .compactMap { SettingsValidator.SizeComponent.parse(String($0)) }
        let vertical = position == "top" || position == "bottom" || position == "center"
        func fraction(_ c: SettingsValidator.SizeComponent?, axisPixels: Double) -> Double? {
            guard let c else { return nil }
            switch c.unit {
            case .percent: return c.value / 100
            case .pixels: return min(1, c.value / axisPixels)
            }
        }
        let primary = fraction(parts.first, axisPixels: vertical ? 900 : 1440) ?? (position == "center" ? 0.5 : 0.25)
        let secondary = fraction(parts.count > 1 ? parts[1] : nil, axisPixels: vertical ? 1440 : 900)
        return (primary, secondary)
    }
}

/// A tiny screen with a menu bar and the drawer drawn where it will appear.
struct DrawerSchematic: View {
    let position: String
    let size: (primary: Double, secondary: Double?)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let menu: CGFloat = 8
            let usable = CGRect(x: 0, y: menu, width: w, height: h - menu)
            let rect = drawerRect(in: usable)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor))
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.5))
                Rectangle().fill(Color.secondary.opacity(0.25))
                    .frame(width: w, height: menu)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .animation(.easeOut(duration: 0.15), value: position)
            }
        }
    }

    private func drawerRect(in r: CGRect) -> CGRect {
        let p = CGFloat(min(max(size.primary, 0.05), 1))
        let s = CGFloat(min(max(size.secondary ?? 1, 0.05), 1))
        switch position {
        case "bottom":
            let width = r.width * s
            return CGRect(x: r.midX - width / 2, y: r.maxY - r.height * p, width: width, height: r.height * p)
        case "left":
            let height = r.height * s
            return CGRect(x: r.minX, y: r.midY - height / 2, width: r.width * p, height: height)
        case "right":
            let height = r.height * s
            return CGRect(x: r.maxX - r.width * p, y: r.midY - height / 2, width: r.width * p, height: height)
        case "center":
            let width = r.width * (size.secondary == nil ? 0.5 : s)
            return CGRect(x: r.midX - width / 2, y: r.midY - r.height * p / 2, width: width, height: r.height * p)
        default: // top
            let width = r.width * s
            return CGRect(x: r.midX - width / 2, y: r.minY, width: width, height: r.height * p)
        }
    }
}

/// Edits `quick-terminal-size` as one or two `<number><%|px>` components.
struct QuickTerminalSizeEditor: View {
    @ObservedObject var store: SettingsConfigStore

    @State private var primary = SettingsValidator.SizeComponent(value: 25, unit: .percent)
    @State private var secondary = SettingsValidator.SizeComponent(value: 100, unit: .percent)
    @State private var useSecondary = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            componentRow("Primary", $primary)
            Toggle("Set secondary size", isOn: $useSecondary)
            if useSecondary {
                componentRow("Secondary", $secondary)
            }
            HStack {
                Spacer()
                Button("Apply Size", action: commit)
            }
            ConfigKeyStatus(store: store, key: "quick-terminal-size")
        }
        .disabled(store.isOverridden("quick-terminal-size"))
        .onAppear(perform: loadOnce)
    }

    private func componentRow(_ title: String, _ component: Binding<SettingsValidator.SizeComponent>) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            TextField(title, value: component.value, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .frame(width: 80)
                .onSubmit(commit)
            Picker(title, selection: component.unit) {
                Text("%").tag(SettingsValidator.SizeComponent.Unit.percent)
                Text("px").tag(SettingsValidator.SizeComponent.Unit.pixels)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 90)
            if !component.wrappedValue.isValid {
                Text(component.wrappedValue.unit == .percent ? "1–100%" : "1–10000px")
                    .font(.caption).foregroundColor(.red)
            }
        }
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        let parts = (store.displayValue(for: "quick-terminal-size") ?? "")
            .split(separator: ",")
            .compactMap { SettingsValidator.SizeComponent.parse(String($0)) }
        if let first = parts.first { primary = first }
        if parts.count > 1 {
            secondary = parts[1]
            useSecondary = true
        }
    }

    private func commit() {
        var text = primary.text
        if useSecondary { text += ",\(secondary.text)" }
        store.set("quick-terminal-size", text)
    }
}
