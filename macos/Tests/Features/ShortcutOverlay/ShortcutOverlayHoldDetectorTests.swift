import AppKit
import Testing
@testable import Ghostty

struct ShortcutOverlayHoldDetectorTests {
    private func armed(_ trigger: NSEvent.ModifierFlags = .control) -> ShortcutOverlayHoldDetector {
        var d = ShortcutOverlayHoldDetector(trigger: trigger)
        #expect(d.flagsChanged(trigger) == .startTimer)
        #expect(d.state == .armed)
        return d
    }

    private func showing() -> ShortcutOverlayHoldDetector {
        var d = armed()
        #expect(d.timerFired() == .show)
        #expect(d.state == .showing)
        return d
    }

    @Test func delayElapsingShows() {
        var d = armed()
        #expect(d.timerFired() == .show)
        #expect(d.state == .showing)
    }

    @Test func repeatedSameFlagsDoNotResetTheTimer() {
        var d = armed()
        #expect(d.flagsChanged(.control) == .none)
        #expect(d.flagsChanged([.control, .capsLock]) == .none)
        #expect(d.flagsChanged([.control, .function]) == .none)
        #expect(d.state == .armed)
        var s = showing()
        #expect(s.flagsChanged(.control) == .none)
        #expect(s.state == .showing)
    }

    @Test func otherKeyCancelsAndBlocksUntilRelease() {
        var d = armed()
        #expect(d.otherInput() == .cancelTimer)
        #expect(d.state == .blocked)
        // A late timer does nothing.
        #expect(d.timerFired() == .none)
        // Still holding Control (Ctrl-C, Ctrl-R...): stays blocked.
        #expect(d.flagsChanged(.control) == .none)
        #expect(d.otherInput() == .none)
        #expect(d.state == .blocked)
        // Release, then a fresh hold arms again.
        #expect(d.flagsChanged([]) == .none)
        #expect(d.state == .idle)
        #expect(d.flagsChanged(.control) == .startTimer)
    }

    /// A keyDown consumed by an earlier monitor (or the system) never arrives; its
    /// keyUp does, and is reported as other input too.
    @Test func keyUpAloneStillCancels() {
        var d = armed()
        #expect(d.otherInput() == .cancelTimer) // keyUp of the consumed key
        #expect(d.timerFired() == .none)
        #expect(d.state == .blocked)
    }

    @Test func addingAnotherModifierCancels() {
        var d = armed()
        #expect(d.flagsChanged([.control, .shift]) == .cancelTimer)
        #expect(d.state == .blocked)
        // Dropping Shift while Control is still down doesn't re-arm.
        #expect(d.flagsChanged(.control) == .none)
        #expect(d.state == .blocked)
    }

    @Test func releaseBeforeDelayCancels() {
        var d = armed()
        #expect(d.flagsChanged([]) == .cancelTimer)
        #expect(d.state == .idle)
        #expect(d.timerFired() == .none)
    }

    @Test func releaseHides() {
        var d = showing()
        #expect(d.flagsChanged([]) == .hide)
        #expect(d.state == .idle)
    }

    @Test func keyOrMouseHides() {
        var d = showing()
        #expect(d.otherInput() == .hide)
        #expect(d.state == .blocked)
        var e = showing()
        #expect(e.flagsChanged([.control, .option]) == .hide)
        #expect(e.state == .blocked)
    }

    @Test func deactivateCancelsOrHides() {
        var a = armed()
        #expect(a.deactivated() == .cancelTimer)
        #expect(a.state == .idle)
        var s = showing()
        #expect(s.deactivated() == .hide)
        #expect(s.state == .idle)
        var i = ShortcutOverlayHoldDetector(trigger: .control)
        #expect(i.deactivated() == .none)
    }

    @Test func otherModifiersAloneDoNothing() {
        var d = ShortcutOverlayHoldDetector(trigger: .control)
        #expect(d.flagsChanged(.command) == .none)
        #expect(d.flagsChanged([.command, .control]) == .none)
        #expect(d.state == .idle)
        #expect(!d.isTracking)
    }

    @Test func modifierPressedWithAnotherFirstNeverArms() {
        var d = ShortcutOverlayHoldDetector(trigger: .control)
        #expect(d.flagsChanged(.shift) == .none)
        #expect(d.flagsChanged([.shift, .control]) == .none)
        #expect(d.state == .idle)
    }

    @Test func offNeverArms() {
        var d = ShortcutOverlayHoldDetector(trigger: nil)
        #expect(d.flagsChanged(.control) == .none)
        #expect(d.timerFired() == .none)
        #expect(d.state == .idle)
    }

    @Test func commandAndOptionTriggers() {
        var c = armed(.command)
        #expect(c.timerFired() == .show)
        var o = ShortcutOverlayHoldDetector(trigger: .option)
        #expect(o.flagsChanged(.control) == .none)
        #expect(o.flagsChanged([]) == .none)
        #expect(o.flagsChanged(.option) == .startTimer)
    }

    @Test func changingTriggerResets() {
        var s = showing()
        #expect(s.setTrigger(.command) == .hide)
        #expect(s.state == .idle)
        #expect(s.flagsChanged(.control) == .none)
        var a = armed()
        #expect(a.setTrigger(nil) == .cancelTimer)
        #expect(a.flagsChanged(.control) == .none)
    }
}
