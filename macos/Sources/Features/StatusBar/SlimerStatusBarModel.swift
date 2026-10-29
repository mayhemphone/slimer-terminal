import AppKit
import Combine
import ObjectiveC

/// Per-surface state behind the status bar.
///
/// The bar view observes this model, never the `SurfaceView` itself: the surface
/// publishes on mouse movement, cursor blinks and resizes, and the bar must only
/// re-render when something it shows changes. Each input is de-duplicated
/// before it reaches a `@Published` property.
///
/// One model exists per surface (stored as an associated object), so it survives
/// SwiftUI rebuilding the split tree and keeps exactly one git subscription.
@MainActor
final class SlimerStatusBarModel: ObservableObject {
    /// The surface's working directory (OSC 7), unabbreviated.
    @Published private(set) var pwd: String?
    /// `user@host` when the title looks like a default shell title.
    @Published private(set) var userHost: String?
    /// Git state of `pwd`'s repository, `nil` outside a repository.
    @Published private(set) var git: GitRepoState?
    /// The most recently finished command.
    @Published private(set) var lastCommand: SlimerCommandFinished.Event?
    /// The foreground process is Claude Code.
    @Published private(set) var isClaudeForeground = false

    private(set) weak var surfaceView: Ghostty.SurfaceView?

    private var cancellables: Set<AnyCancellable> = []
    private var gitCancellable: AnyCancellable?
    private var observedDirectory: String?

    private static var associationKey: UInt8 = 0

    /// The model for `surfaceView`, created on first use.
    static func model(for surfaceView: Ghostty.SurfaceView) -> SlimerStatusBarModel {
        if let existing = objc_getAssociatedObject(surfaceView, &associationKey) as? SlimerStatusBarModel {
            return existing
        }
        let model = SlimerStatusBarModel(surfaceView: surfaceView)
        objc_setAssociatedObject(surfaceView, &associationKey, model, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return model
    }

    private init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView

        surfaceView.$pwd
            .removeDuplicates()
            .sink { [weak self] pwd in self?.pwdChanged(pwd) }
            .store(in: &cancellables)

        // Titles can change many times a second (spinners). Look at most once a
        // second, always ending on the latest title.
        surfaceView.$title
            .removeDuplicates()
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] title in self?.titleChanged(title) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: SlimerCommandFinished.notification, object: surfaceView)
            .sink { [weak self] notification in
                guard let event = SlimerCommandFinished.Event(notification: notification) else { return }
                self?.commandFinished(event)
            }
            .store(in: &cancellables)
    }

    // MARK: Inputs

    private func pwdChanged(_ newValue: String?) {
        let value = newValue.flatMap { $0.isEmpty ? nil : $0 }
        if pwd != value { pwd = value }
        subscribeGit(directory: value)
    }

    private func titleChanged(_ title: String) {
        let host = StatusBarFormatting.userHost(fromTitle: title)
        if userHost != host { userHost = host }
        refreshClaudeForeground()
    }

    private func commandFinished(_ event: SlimerCommandFinished.Event) {
        lastCommand = event
        if let pwd {
            GitStatusService.shared.refresh(directory: URL(fileURLWithPath: pwd, isDirectory: true))
        }
        refreshClaudeForeground()
    }

    // MARK: Git

    private func subscribeGit(directory: String?) {
        guard directory != observedDirectory else { return }
        observedDirectory = directory
        gitCancellable = nil
        guard let directory else {
            if git != nil { git = nil }
            return
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        gitCancellable = GitStatusService.shared.observe(directory: url)
            // `updatedAt` changes on every refresh; ignore it so an unchanged
            // repository never re-renders the bar.
            .map { state in state.map(Self.withoutTimestamp) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.git != state else { return }
                self.git = state
            }
    }

    private nonisolated static func withoutTimestamp(_ state: GitRepoState) -> GitRepoState {
        var copy = state
        copy.updatedAt = Date(timeIntervalSince1970: 0)
        return copy
    }

    // MARK: Claude

    private func refreshClaudeForeground() {
        let isClaude: Bool
        if let pid = surfaceView?.surfaceModel?.foregroundPID {
            isClaude = ClaudeProcessDetector.isClaude(pid: pid)
        } else {
            isClaude = false
        }
        if isClaudeForeground != isClaude { isClaudeForeground = isClaude }
    }
}
