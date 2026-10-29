import AppKit
import GhosttyKit
import SwiftUI

extension View {
    /// Attach the Slimer status bar to a terminal surface view, honoring
    /// `slimer-status-bar`. The bar takes layout space (the terminal grid
    /// shrinks by its height once) and never overlays terminal cells.
    func slimerStatusBar(_ surfaceView: Ghostty.SurfaceView, isSplit: Bool = false) -> some View {
        modifier(SlimerStatusBarModifier(surfaceView: surfaceView, isSplit: isSplit))
    }
}

struct SlimerStatusBarModifier: ViewModifier {
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool

    @EnvironmentObject private var ghostty: Ghostty.App
    @Environment(\.ghosttyLastFocusedSurface) private var lastFocusedSurface

    func body(content: Content) -> some View {
        let position = ghostty.config.slimerStatusBar
        GeometryReader { geo in
            // Very short panes keep every row for the terminal.
            let show = position != .hidden && SlimerStatusBar.fits(inLeafHeight: geo.size.height)
            VStack(spacing: 0) {
                if show && position == .top {
                    bar(position)
                }
                content
                if show && position == .bottom {
                    bar(position)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
        .onAppear { releaseModelIfHidden(position) }
        .onChange(of: position) { releaseModelIfHidden($0) }
    }

    /// The bar dims with its pane, like the surface's own unfocused-split overlay,
    /// so in a stack it reads as part of the terminal above (or below), not the next one.
    private func bar(_ position: Ghostty.Config.SlimerStatusBarPosition) -> some View {
        SlimerStatusBar(
            surfaceView: surfaceView,
            fallbackBackground: ghostty.config.backgroundColor,
            edge: position == .top ? .bottom : .top
        )
        .overlay {
            let opacity = ghostty.config.unfocusedSplitOpacity
            if isSplit && lastFocusedSurface?.value !== surfaceView && opacity > 0 {
                Rectangle()
                    .fill(ghostty.config.unfocusedSplitFill)
                    .opacity(opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Hiding the bar at runtime frees the surface's model and its git
    /// subscription; showing it again creates a fresh one.
    private func releaseModelIfHidden(_ position: Ghostty.Config.SlimerStatusBarPosition) {
        guard position == .hidden else { return }
        SlimerStatusBarModel.removeModel(for: surfaceView)
    }
}

/// The ~22pt bar: cwd, user@host, git, last command on the left; Claude on the right.
struct SlimerStatusBar: View {
    static let height: CGFloat = 22

    /// The bar only shows in leaves at least this many bar heights tall.
    static let minimumLeafHeightMultiple: CGFloat = 3

    static func fits(inLeafHeight leafHeight: CGFloat) -> Bool {
        leafHeight >= height * minimumLeafHeightMultiple
    }

    /// Height to add to a surface's requested initial size (`window-height`)
    /// so the terminal still gets the configured rows when the bar shows.
    /// Main thread only (called from the initial-size action handler).
    static var initialHeightExtra: CGFloat {
        initialHeightExtra(for: (NSApplication.shared.delegate as? AppDelegate)?.ghostty.config.slimerStatusBar ?? .bottom)
    }

    static func initialHeightExtra(for position: Ghostty.Config.SlimerStatusBarPosition) -> CGFloat {
        position == .hidden ? 0 : height
    }

    @ObservedObject private var model: SlimerStatusBarModel
    private let fallbackBackground: Color

    /// The edge that touches the bar's own terminal. The tint fades in from there,
    /// so the bar blends into its pane and has a crisp edge only at the split divider.
    private let edge: VerticalEdge

    @State private var showGitPopover = false

    init(surfaceView: Ghostty.SurfaceView, fallbackBackground: Color, edge: VerticalEdge = .top) {
        self.model = SlimerStatusBarModel.model(for: surfaceView)
        self.fallbackBackground = fallbackBackground
        self.edge = edge
    }

    var body: some View {
        HStack(spacing: 4) {
            if let pwd = model.pwd {
                cwdChip(pwd)
            }
            if let userHost = model.userHost {
                StatusChip(systemImage: "person.crop.circle", text: userHost)
                    .help("Shell host (from the terminal title)")
            }
            if let git = model.git {
                gitChip(git)
            }
            if let last = model.lastCommand {
                LastCommandChip(event: last)
            }
            Spacer(minLength: 4)
            if model.isClaudeForeground {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
                    .help("Claude Code is running in this terminal")
                    .accessibilityLabel("Claude Code running")
            }
            ClaudeButton(surfaceView: model.surfaceView)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(background.overlay(tint))
        .environment(\.colorScheme, NSColor(background).isLightColor ? .light : .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal status bar")
    }

    private var background: Color {
        model.background ?? fallbackBackground
    }

    private var tint: some View {
        Color.primary.opacity(0.09).mask(
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.6)],
                startPoint: edge == .top ? .top : .bottom,
                endPoint: edge == .top ? .bottom : .top
            )
        )
    }

    // MARK: Chips

    private func cwdChip(_ pwd: String) -> some View {
        Menu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pwd, forType: .string)
            }
            Button("Open in Finder") {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: pwd, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return }
                NSWorkspace.shared.open(URL(fileURLWithPath: pwd, isDirectory: true))
            }
            Button("Open in New Tab") {
                guard let surfaceView = model.surfaceView else { return }
                SlimerStatusBarActions.openNewTab(from: surfaceView, workingDirectory: pwd)
            }
        } label: {
            StatusChip(systemImage: "folder", text: StatusBarFormatting.abbreviate(path: pwd))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(pwd)
    }

    private func gitChip(_ git: GitRepoState) -> some View {
        Button {
            showGitPopover.toggle()
        } label: {
            GitChipLabel(state: git)
        }
        .buttonStyle(.plain)
        .help("Git: \(SlimerUnsafeText.sanitizedForDisplay(git.headLabel))")
        .popover(isPresented: $showGitPopover, arrowEdge: .bottom) {
            if let surfaceView = model.surfaceView {
                GitPopoverView(state: git, surfaceView: surfaceView) {
                    showGitPopover = false
                }
            }
        }
    }
}

/// A small icon + text chip.
struct StatusChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
            Text(text)
                .truncationMode(.head)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

struct GitChipLabel: View {
    let state: GitRepoState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.isDetached ? "smallcircle.filled.circle" : "arrow.triangle.branch")
                .font(.system(size: 9))
            // Branch names come from the repository (untrusted); display only.
            Text(SlimerUnsafeText.sanitizedForDisplay(state.headLabel))
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if state.staged > 0 { Text("+\(state.staged)").foregroundColor(.green) }
            if state.unstaged > 0 { Text("~\(state.unstaged)").foregroundColor(.yellow) }
            if state.untracked > 0 { Text("?\(state.untracked)") }
            if state.conflicted > 0 { Text("!\(state.conflicted)").foregroundColor(.red) }
            if state.ahead > 0 { Text("⇡\(state.ahead)") }
            if state.behind > 0 { Text("⇣\(state.behind)") }
            if state.stashCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "tray.full").font(.system(size: 9))
                    Text("\(state.stashCount)")
                }
            }
            if let operation = state.operation {
                Text(StatusBarFormatting.operationBadge(operation))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.orange)
            }
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

struct LastCommandChip: View {
    let event: SlimerCommandFinished.Event

    var body: some View {
        let duration = StatusBarFormatting.duration(nanoseconds: event.durationNanoseconds)
        HStack(spacing: 3) {
            switch event.succeeded {
            case .some(true):
                Text("✓").foregroundColor(.green)
            case .some(false):
                Text("✗ \(event.exitCode ?? 0)").foregroundColor(.red)
            case .none:
                Text("•")
            }
            Text(duration)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 4)
        .help(helpText(duration: duration))
    }

    private func helpText(duration: String) -> String {
        guard let code = event.exitCode else { return "Last command took \(duration)" }
        return "Last command exited \(code) after \(duration)"
    }
}

/// Actions shared by the bar, the popover and the Claude menu.
@MainActor
enum SlimerStatusBarActions {
    /// Open a new tab next to `surfaceView` (normal window or drawer) in `workingDirectory`.
    static func openNewTab(from surfaceView: Ghostty.SurfaceView, workingDirectory: String) {
        var config = inheritedConfig(from: surfaceView, context: GHOSTTY_SURFACE_CONTEXT_TAB)
        config.workingDirectory = workingDirectory
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyNewTab,
            object: surfaceView,
            userInfo: [Ghostty.Notification.NewSurfaceConfigKey: config]
        )
    }

    /// The config a keybind-created tab or split of `surfaceView` would get
    /// (font size, working directory, environment).
    static func inheritedConfig(
        from surfaceView: Ghostty.SurfaceView,
        context: ghostty_surface_context_e
    ) -> Ghostty.SurfaceConfiguration {
        guard let surface = surfaceView.surface else { return Ghostty.SurfaceConfiguration() }
        return Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, context))
    }

    /// Open an https github.com URL in the browser. Anything else is ignored.
    static func openGitHub(_ url: URL?) {
        guard let url, url.scheme == "https", url.host == "github.com" else { return }
        NSWorkspace.shared.open(url)
    }
}
