import AppKit

/// The hold-to-show state machine for the shortcut sheet. Pure value type: it never
/// touches events, timers or windows, it only says what the controller should do.
///
/// The sheet appears when the trigger modifier is held on its own for the delay.
/// Anything else (another modifier, a key, a click, the app deactivating) cancels the
/// timer or hides the sheet, and the trigger must be released before it can arm again,
/// so Ctrl-C or Ctrl-R never show it.
struct ShortcutOverlayHoldDetector: Equatable {
    enum State: Equatable {
        /// Waiting for the trigger modifier to go down alone.
        case idle
        /// The trigger is held alone and the delay timer is running.
        case armed
        /// The sheet is visible.
        case showing
        /// The trigger is still held but something else happened; wait for release.
        case blocked
    }

    enum Effect: Equatable {
        case none
        case startTimer
        case cancelTimer
        case show
        case hide
    }

    /// The modifiers that count. Caps Lock, Fn and the numeric-pad flag are ignored.
    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// The modifier to hold, or nil when the feature is off.
    private(set) var trigger: NSEvent.ModifierFlags?
    private(set) var state: State = .idle

    init(trigger: NSEvent.ModifierFlags?) {
        self.trigger = trigger.map { $0.intersection(Self.relevantModifiers) }
    }

    /// True when keyDown and mouse events need to reach `otherInput()`. When false the
    /// monitor can skip them entirely.
    var isTracking: Bool { state != .idle }

    /// Changes the trigger. Anything in flight is cancelled.
    mutating func setTrigger(_ newValue: NSEvent.ModifierFlags?) -> Effect {
        let effect = reset()
        trigger = newValue.map { $0.intersection(Self.relevantModifiers) }
        return effect
    }

    mutating func flagsChanged(_ flags: NSEvent.ModifierFlags) -> Effect {
        guard let trigger, !trigger.isEmpty else { return .none }
        let mods = flags.intersection(Self.relevantModifiers)
        let alone = mods == trigger
        let held = mods.contains(trigger)

        switch state {
        case .idle:
            guard alone else { return .none }
            state = .armed
            return .startTimer

        case .armed:
            // Repeated flagsChanged with the same flags must not restart the timer.
            if alone { return .none }
            state = held ? .blocked : .idle
            return .cancelTimer

        case .showing:
            if alone { return .none }
            state = held ? .blocked : .idle
            return .hide

        case .blocked:
            if !held { state = .idle }
            return .none
        }
    }

    /// A key press, a mouse button, or a scroll while tracking.
    mutating func otherInput() -> Effect {
        switch state {
        case .idle, .blocked:
            return .none
        case .armed:
            state = .blocked
            return .cancelTimer
        case .showing:
            state = .blocked
            return .hide
        }
    }

    mutating func timerFired() -> Effect {
        guard state == .armed else { return .none }
        state = .showing
        return .show
    }

    /// The app resigned active, or the key window went away.
    mutating func deactivated() -> Effect {
        reset()
    }

    private mutating func reset() -> Effect {
        let previous = state
        state = .idle
        switch previous {
        case .idle, .blocked: return .none
        case .armed: return .cancelTimer
        case .showing: return .hide
        }
    }
}
