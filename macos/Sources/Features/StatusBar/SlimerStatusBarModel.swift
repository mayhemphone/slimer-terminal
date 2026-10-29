import AppKit
import Combine
import ObjectiveC
import SwiftUI

/// Per-surface state behind the status bar.
///
/// The bar view observes this model, never the `SurfaceView` itself: the surface
/// publishes on mouse movement, cursor blinks and resizes, and the bar must only
/// re-render when something it shows changes. Each input is de-duplicated
/// before it reaches a `@Published` property.
///
/// One model exists per surface, stored as an associated object of the surface
/// so it survives SwiftUI rebuilding the split tree and keeps exactly one git
/// subscription. Because the surface retains the model, nothing the model owns
/// may retain the surface: every subscription captures it weakly (in
/// particular, `NotificationCenter.publisher(for:object:)` is never used, since
/// it holds its `object` strongly). `SlimerStatusBarModelTests` checks this.
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
    /// The surface's own background (runtime OSC 11 color, else its config),
    /// so per-tab themes match. `nil` until known.
    @Published private(set) var background: Color?

    /// The surface this model belongs to (weak; the surface owns the model).
    private(set) weak var owner: AnyObject?
    var surfaceView: Ghostty.SurfaceView? { owner as? Ghostty.SurfaceView }

    private let foregroundPID: @MainActor () -> Int?
    private var cancellables: Set<AnyCancellable> = []
    private var gitCancellable: AnyCancellable?
    private var observedDirectory: String?

    private static var associationKey: UInt8 = 0

    /// The model for `surfaceView`, created on first use.
    static func model(for surfaceView: Ghostty.SurfaceView) -> SlimerStatusBarModel {
        model(
            for: surfaceView,
            pwd: surfaceView.$pwd.eraseToAnyPublisher(),
            title: surfaceView.$title.eraseToAnyPublisher(),
            background: surfaceView.$backgroundColor
                .combineLatest(surfaceView.$derivedConfig.map(\.backgroundColor))
                .map { dynamic, configured in dynamic ?? configured }
                .eraseToAnyPublisher(),
            foregroundPID: { [weak surfaceView] in surfaceView?.surfaceModel?.foregroundPID }
        )
    }

    /// The model attached to `owner`, created from the given inputs on first use.
    /// Separate from the SurfaceView overload so tests can use a plain object.
    static func model(
        for owner: AnyObject,
        pwd: AnyPublisher<String?, Never>,
        title: AnyPublisher<String, Never>,
        background: AnyPublisher<Color, Never>? = nil,
        foregroundPID: @escaping @MainActor () -> Int?
    ) -> SlimerStatusBarModel {
        if let existing = existingModel(for: owner) { return existing }
        let model = SlimerStatusBarModel(
            owner: owner,
            pwd: pwd,
            title: title,
            background: background,
            foregroundPID: foregroundPID
        )
        objc_setAssociatedObject(owner, &associationKey, model, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return model
    }

    static func existingModel(for owner: AnyObject) -> SlimerStatusBarModel? {
        objc_getAssociatedObject(owner, &associationKey) as? SlimerStatusBarModel
    }

    /// Drop the model of `owner` (the bar was hidden). Its subscriptions,
    /// including the git watcher reference, go with it.
    static func removeModel(for owner: AnyObject) {
        guard existingModel(for: owner) != nil else { return }
        objc_setAssociatedObject(owner, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private init(
        owner: AnyObject,
        pwd: AnyPublisher<String?, Never>,
        title: AnyPublisher<String, Never>,
        background: AnyPublisher<Color, Never>?,
        foregroundPID: @escaping @MainActor () -> Int?
    ) {
        self.owner = owner
        self.foregroundPID = foregroundPID

        pwd
            .removeDuplicates()
            .sink { [weak self] pwd in self?.pwdChanged(pwd) }
            .store(in: &cancellables)

        // Titles can change many times a second (spinners). Look at most once a
        // second, always ending on the latest title.
        title
            .removeDuplicates()
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] title in self?.titleChanged(title) }
            .store(in: &cancellables)

        background?
            .removeDuplicates()
            .sink { [weak self] color in
                guard let self, self.background != color else { return }
                self.background = color
            }
            .store(in: &cancellables)

        // No `object:` filter here: that would retain the owner (a cycle).
        NotificationCenter.default.publisher(for: SlimerCommandFinished.notification)
            .sink { [weak self] notification in
                guard let self, let owner = self.owner, notification.object as AnyObject? === owner,
                      let event = SlimerCommandFinished.Event(notification: notification) else { return }
                self.commandFinished(event)
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
        let isClaude = foregroundPID().map(ClaudeProcessDetector.isClaude(pid:)) ?? false
        if isClaudeForeground != isClaude { isClaudeForeground = isClaude }
    }
}
