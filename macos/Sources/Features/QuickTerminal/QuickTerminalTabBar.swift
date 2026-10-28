import SwiftUI
import GhosttyKit

// slimer: the compact tab strip shown above the splits in the quick terminal.
//
// The strip observes `QuickTerminalTabBarModel`, which the controller updates only
// when tab metadata (titles, selection, bell) changes. Split-tree churn inside a tab
// never invalidates the strip. Deliberately plain: no List, no materials, no
// animations, so it costs nothing on the render path.

/// Observable state for the drawer tab bar.
final class QuickTerminalTabBarModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: UUID
        var title: String
        var bell: Bool
        /// Placeholder for a future per-tab accent color. Nil renders a neutral dot.
        var color: Color?
    }

    struct Style: Equatable {
        var background: Color
        var foreground: Color

        static let fallback = Style(
            background: Color(nsColor: .windowBackgroundColor),
            foreground: Color(nsColor: .textColor))
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var visibility: QuickTerminalTabBar = .auto
    @Published private(set) var style: Style = .fallback

    /// Callbacks wired by the controller. These run on the main thread from
    /// SwiftUI button actions.
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNew: (() -> Void)?

    var isVisible: Bool {
        visibility.isVisible(tabCount: items.count)
    }

    /// Replace the item list and selection. Publishes only when something changed.
    func update(items: [Item], selectedID: UUID?) {
        if self.items != items { self.items = items }
        if self.selectedID != selectedID { self.selectedID = selectedID }
    }

    func update(visibility: QuickTerminalTabBar) {
        if self.visibility != visibility { self.visibility = visibility }
    }

    /// Derive the strip colors from the terminal background so the strip reads as
    /// part of the drawer rather than a system toolbar.
    func update(backgroundColor: NSColor, backgroundOpacity: Double) {
        let tint: NSColor = backgroundColor.isLightColor ? .black : .white
        let background = backgroundColor.blended(withFraction: 0.08, of: tint) ?? backgroundColor
        let newStyle = Style(
            background: Color(nsColor: background).opacity(backgroundOpacity),
            foreground: Color(nsColor: tint))
        if style != newStyle { style = newStyle }
    }
}

/// The strip itself. Renders nothing when the model says it is hidden so the
/// splits take the full window.
struct QuickTerminalTabBarView: View {
    @ObservedObject var model: QuickTerminalTabBarModel
    @State private var hoveredID: UUID?

    static let height: CGFloat = 28

    var body: some View {
        if model.isVisible {
            HStack(spacing: 2) {
                ForEach(model.items) { item in
                    QuickTerminalTabItemView(
                        item: item,
                        isSelected: item.id == model.selectedID,
                        isHovered: item.id == hoveredID,
                        foreground: model.style.foreground,
                        onSelect: { model.onSelect?(item.id) },
                        onClose: { model.onClose?(item.id) })
                    .onHover { inside in
                        if inside {
                            hoveredID = item.id
                        } else if hoveredID == item.id {
                            hoveredID = nil
                        }
                    }
                }

                Button {
                    model.onNew?()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.style.foreground.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Tab")
                .accessibilityLabel("New Tab")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .background(model.style.background)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
        }
    }
}

private struct QuickTerminalTabItemView: View {
    let item: QuickTerminalTabBarModel.Item
    let isSelected: Bool
    let isHovered: Bool
    let foreground: Color
    let onSelect: () -> Void
    let onClose: () -> Void

    private var backgroundOpacity: Double {
        if isSelected { return 0.16 }
        if isHovered { return 0.08 }
        return 0
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(item.color ?? foreground.opacity(0.3))
                .frame(width: 6, height: 6)

            Text(item.bell ? "🔔 \(item.title)" : item.title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundStyle(foreground.opacity(isSelected ? 1 : 0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // The close button is always laid out so the title doesn't jump on
            // hover; it is only visible when hovered or selected.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(foreground.opacity(isHovered ? 0.9 : 0.5))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isSelected ? 1 : 0)
            .help("Close Tab")
            .accessibilityLabel("Close Tab")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(foreground.opacity(backgroundOpacity)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// Hosts the tab strip above the terminal content inside the drawer window.
struct QuickTerminalContentView<Content: View>: View {
    let tabBar: QuickTerminalTabBarModel
    let content: Content

    init(tabBar: QuickTerminalTabBarModel, @ViewBuilder content: () -> Content) {
        self.tabBar = tabBar
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            QuickTerminalTabBarView(model: tabBar)
            content
        }
    }
}

/// `quick-terminal-tab-bar`: when the drawer tab strip is shown.
enum QuickTerminalTabBar: String {
    /// Only when there is more than one tab.
    case auto
    case always
    case never

    func isVisible(tabCount: Int) -> Bool {
        switch self {
        case .auto: return tabCount > 1
        case .always: return true
        case .never: return false
        }
    }
}

extension Ghostty.Config {
    var quickTerminalTabBar: QuickTerminalTabBar {
        guard let config = self.config else { return .auto }
        var v: UnsafePointer<Int8>?
        let key = "quick-terminal-tab-bar"
        guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return .auto }
        guard let ptr = v else { return .auto }
        return QuickTerminalTabBar(rawValue: String(cString: ptr)) ?? .auto
    }
}
