import SwiftUI

/// The Settings window: a sidebar of panes. Only the selected pane is built, so opening
/// the window does no work for panes you don't look at.
struct SlimerSettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general
        case drawer
        case appearance
        case themes
        case workspace
        case git
        case claude
        case advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .drawer: return "Drawer"
            case .appearance: return "Appearance"
            case .themes: return "Themes & Tabs"
            case .workspace: return "Locations & Commands"
            case .git: return "Git & Status Bar"
            case .claude: return "Claude"
            case .advanced: return "Advanced"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .drawer: return "rectangle.bottomhalf.inset.filled"
            case .appearance: return "paintbrush"
            case .themes: return "swatchpalette"
            case .workspace: return "folder"
            case .git: return "arrow.triangle.branch"
            case .claude: return "sparkle"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    @ObservedObject var config: SettingsConfigStore
    @State private var selection: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail(for: selection ?? .general)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle((selection ?? .general).title)
        }
        .frame(minWidth: 760, minHeight: 580)
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .general: GeneralPane(store: config)
        case .drawer: DrawerPane(store: config)
        case .appearance: AppearancePane(store: config)
        case .themes: ThemesPane()
        case .workspace: WorkspacePane()
        case .git: GitStatusBarPane(store: config)
        case .claude: ClaudePane()
        case .advanced: AdvancedPane(store: config)
        }
    }
}
