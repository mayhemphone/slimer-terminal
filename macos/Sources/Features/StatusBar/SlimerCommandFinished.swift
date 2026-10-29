import Foundation

/// Bridge for Ghostty's `COMMAND_FINISHED` action (OSC 133 D with shell
/// integration) to the status bar.
///
/// Upstream only turns the action into a desktop notification or bell, and
/// only under `notify-on-command-finish`. `Ghostty.App.commandFinished` calls
/// `post` (one `// slimer:` line) for every surface-targeted action before
/// those filters, and the per-surface status bar model observes it.
enum SlimerCommandFinished {
    static let notification = Notification.Name("top.mayhem.slimer.commandFinished")
    static let exitCodeKey = "exitCode"
    static let durationKey = "durationNanoseconds"

    /// A finished command as reported by the core.
    struct Event: Equatable {
        /// Exit status 0-255, or `nil` when the shell did not report one.
        var exitCode: Int?
        var durationNanoseconds: UInt64

        var succeeded: Bool? { exitCode.map { $0 == 0 } }

        init(exitCode: Int?, durationNanoseconds: UInt64) {
            self.exitCode = exitCode
            self.durationNanoseconds = durationNanoseconds
        }

        init?(notification: Notification) {
            guard let duration = notification.userInfo?[SlimerCommandFinished.durationKey] as? UInt64 else { return nil }
            let code = notification.userInfo?[SlimerCommandFinished.exitCodeKey] as? Int
            self.init(exitCode: code, durationNanoseconds: duration)
        }
    }

    /// Post a command-finished event for `surfaceView`. `exitCode` is the raw C
    /// value (-1 when unknown).
    static func post(surfaceView: AnyObject, exitCode: Int16, duration: UInt64) {
        var info: [String: Any] = [durationKey: duration]
        if exitCode >= 0 { info[exitCodeKey] = Int(exitCode) }
        NotificationCenter.default.post(name: notification, object: surfaceView, userInfo: info)
    }
}
