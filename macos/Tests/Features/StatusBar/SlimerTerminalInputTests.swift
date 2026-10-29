import Testing
import Foundation
@testable import Ghostty

struct SlimerTerminalInputTests {
    // MARK: Enter decision

    @Test func idleShellRunRequestedClearsAndPressesEnter() {
        let plan = SlimerTerminalInput.plan(runRequested: true, hasForegroundProcess: false)
        #expect(plan == .init(clearLine: true, pressEnter: true))
    }

    @Test func idleShellInsertClearsWithoutEnter() {
        let plan = SlimerTerminalInput.plan(runRequested: false, hasForegroundProcess: false)
        #expect(plan == .init(clearLine: true, pressEnter: false))
    }

    @Test(arguments: [true, false])
    func foregroundProcessNeverGetsEnterOrCtrlU(runRequested: Bool) {
        let plan = SlimerTerminalInput.plan(runRequested: runRequested, hasForegroundProcess: true)
        #expect(plan == .init(clearLine: false, pressEnter: false))
    }

    // MARK: Escaping

    @Test func backslashesAreDoubled() {
        #expect(SlimerTerminalInput.escapeForTextAction(#"a\b"#) == #"a\\b"#)
        #expect(SlimerTerminalInput.escapeForTextAction(#"\x15"#) == #"\\x15"#)
        #expect(SlimerTerminalInput.escapeForTextAction(#"\\"#) == #"\\\\"#)
    }

    @Test func otherCharactersPassThrough() {
        let text = #"git switch 'it'\''s' "x" $HOME :colon ü"#
        #expect(SlimerTerminalInput.escapeForTextAction(text) == #"git switch 'it'\\''s' "x" $HOME :colon ü"#)
    }

    @Test func bindingActionWithClearAndEnter() throws {
        let action = try SlimerTerminalInput.bindingAction(
            command: "git pull --ff-only",
            plan: .init(clearLine: true, pressEnter: true)
        )
        #expect(action == #"text:\x15git pull --ff-only\r"#)
    }

    @Test func bindingActionPlain() throws {
        let action = try SlimerTerminalInput.bindingAction(
            command: #"echo a\nb"#,
            plan: .init(clearLine: false, pressEnter: false)
        )
        // The literal backslash-n is doubled so Ghostty types `\n`, not a newline.
        #expect(action == #"text:echo a\\nb"#)
    }

    @Test(arguments: ["", "git push\n", "git push\r", "a\u{15}b", "a\u{7f}", "a\u{202e}b", "a\u{2028}", "a\u{9b}"])
    func rejectsUnsafeCommands(command: String) {
        #expect(throws: SlimerTerminalInput.InputError.self) {
            try SlimerTerminalInput.bindingAction(command: command, plan: .init(clearLine: true, pressEnter: true))
        }
    }
}
