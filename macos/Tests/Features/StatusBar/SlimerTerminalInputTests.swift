import Testing
import Foundation
@testable import Ghostty

struct SlimerTerminalInputTests {
    // MARK: Enter decision

    @Test func idlePromptRunPressesEnter() {
        #expect(SlimerTerminalInput.decide(runRequested: true, idlePrompt: true, confirmedWhileBusy: false)
            == .type(pressEnter: true))
    }

    @Test func idlePromptInsertTypesWithoutEnter() {
        #expect(SlimerTerminalInput.decide(runRequested: false, idlePrompt: true, confirmedWhileBusy: false)
            == .type(pressEnter: false))
    }

    @Test(arguments: [true, false])
    func notIdleNeverRuns(confirmed: Bool) {
        #expect(SlimerTerminalInput.decide(runRequested: true, idlePrompt: false, confirmedWhileBusy: confirmed)
            == .refuseRun)
    }

    @Test func notIdleInsertNeedsConfirmation() {
        #expect(SlimerTerminalInput.decide(runRequested: false, idlePrompt: false, confirmedWhileBusy: false)
            == .needsConfirmation)
        #expect(SlimerTerminalInput.decide(runRequested: false, idlePrompt: false, confirmedWhileBusy: true)
            == .type(pressEnter: false))
    }

    // MARK: Escaping

    @Test func backslashesAreDoubled() {
        #expect(SlimerTerminalInput.escapeForTextAction(#"a\b"#) == #"a\\b"#)
        #expect(SlimerTerminalInput.escapeForTextAction(#"\x15"#) == #"\\x15"#)
        #expect(SlimerTerminalInput.escapeForTextAction(#"\\"#) == #"\\\\"#)
    }

    @Test func otherCharactersPassThrough() {
        let text = #"git switch 'a b' "x" $HOME :colon ü"#
        #expect(SlimerTerminalInput.escapeForTextAction(text) == text)
    }

    @Test func bindingActionWithEnterHasNoLineKill() throws {
        let action = try SlimerTerminalInput.bindingAction(command: "git pull --ff-only", pressEnter: true)
        #expect(action == #"text:git pull --ff-only\r"#)
        #expect(!action.contains("x15"))
    }

    @Test func bindingActionPlain() throws {
        let action = try SlimerTerminalInput.bindingAction(command: #"echo a\nb"#, pressEnter: false)
        // The literal backslash-n is doubled so Ghostty types `\n`, not a newline.
        #expect(action == #"text:echo a\\nb"#)
    }

    @Test(arguments: [
        "", "git push\n", "git push\r", "a\u{15}b", "a\u{7f}", "a\u{202e}b", "a\u{2028}", "a\u{9b}",
        "a\u{200B}b", "a\u{FEFF}b", "a\u{E0041}b",
    ])
    func rejectsUnsafeCommands(command: String) {
        #expect(throws: SlimerTerminalInput.InputError.self) {
            try SlimerTerminalInput.bindingAction(command: command, pressEnter: true)
        }
    }
}

struct SlimerUnsafeTextTests {
    @Test(arguments: [
        "\u{0}", "\n", "\u{1B}", "\u{7F}", "\u{85}", "\u{9F}", // Cc
        "\u{200B}", "\u{200D}", "\u{FEFF}", "\u{00AD}", "\u{E0041}", // Cf
        "\u{200E}", "\u{200F}", "\u{061C}", "\u{202A}", "\u{202E}", "\u{2066}", "\u{2069}", // bidi
        "\u{2028}", "\u{2029}", // Zl, Zp
    ])
    func rejects(scalar: String) {
        #expect(!SlimerUnsafeText.isSafe("a\(scalar)b"))
        #expect(SlimerUnsafeText.sanitizedForDisplay("a\(scalar)b") == "a\u{FFFD}b")
    }

    @Test func acceptsPrintableUnicode() {
        #expect(SlimerUnsafeText.isSafe("feature/ünïcödé-日本 $x 'q' \\"))
        #expect(SlimerUnsafeText.sanitizedForDisplay("main") == "main")
    }
}
