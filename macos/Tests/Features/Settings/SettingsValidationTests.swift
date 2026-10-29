import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Ghostty

/// Slimer: key recorder mapping, value validators and the global keybind planner.
struct KeyTriggerTests {
    @Test func recordsCommandBackquote() {
        #expect(KeyTrigger.trigger(keyCode: kVK_ANSI_Grave, characters: "`", modifiers: [.command]) == "cmd+backquote")
    }

    @Test func modifierOrderIsCanonical() {
        let all: NSEvent.ModifierFlags = [.shift, .option, .control, .command]
        #expect(KeyTrigger.trigger(keyCode: kVK_ANSI_K, characters: "k", modifiers: all) == "cmd+ctrl+alt+shift+k")
    }

    @Test func lettersFollowLayoutCharacters() {
        // AZERTY: the key at the ANSI "Q" position types "a".
        #expect(KeyTrigger.trigger(keyCode: kVK_ANSI_Q, characters: "a", modifiers: [.command]) == "cmd+a")
        // Shifted or non-ASCII characters fall back to the physical letter.
        #expect(KeyTrigger.trigger(keyCode: kVK_ANSI_A, characters: "A", modifiers: [.shift, .command]) == "cmd+shift+a")
        #expect(KeyTrigger.trigger(keyCode: kVK_ANSI_A, characters: "å", modifiers: [.option]) == "alt+a")
    }

    @Test func digitsAndSpecialKeysArePhysical() {
        #expect(KeyTrigger.trigger(keyCode: kVK_ANSI_1, characters: "&", modifiers: [.command]) == "cmd+1")
        #expect(KeyTrigger.trigger(keyCode: kVK_Return, characters: "\r", modifiers: [.command]) == "cmd+enter")
        #expect(KeyTrigger.trigger(keyCode: kVK_UpArrow, characters: nil, modifiers: [.command, .shift]) == "cmd+shift+arrow_up")
        #expect(KeyTrigger.trigger(keyCode: kVK_F12, characters: nil, modifiers: []) == "f12")
        #expect(KeyTrigger.trigger(keyCode: kVK_ANSI_LeftBracket, characters: "[", modifiers: [.control]) == "ctrl+bracket_left")
        #expect(KeyTrigger.trigger(keyCode: kVK_Space, characters: " ", modifiers: [.option]) == "alt+space")
    }

    @Test func rejectsUnnameableKeys() {
        #expect(KeyTrigger.trigger(keyCode: kVK_Command, characters: nil, modifiers: [.command]) == nil)
        #expect(KeyTrigger.trigger(keyCode: kVK_ANSI_Keypad5, characters: "5", modifiers: [.command]) == nil)
        #expect(KeyTrigger.trigger(keyCode: kVK_VolumeUp, characters: nil, modifiers: []) == nil)
    }

    @Test func validatesGrammar() {
        for good in ["cmd+backquote", "f5", "a", "cmd+ctrl+alt+shift+arrow_up", "ctrl+1"] {
            #expect(KeyTrigger.isValid(good), "\(good)")
        }
        for bad in ["", "cmd", "cmd+", "+a", "shift+cmd+a", "cmd+cmd+a", "super+a", "cmd+grave_accent",
                    "cmd+A", "cmd+a+b", "cmd+key_a", "cmd+é", "cmd+f21", "cmd+a\n", "cmd+a=new_window"] {
            #expect(!KeyTrigger.isValid(bad), "\(bad)")
        }
    }

    @Test func globalHotkeysNeedAModifierOrFKey() {
        #expect(KeyTrigger.isValid("f5", requireModifier: true))
        #expect(!KeyTrigger.isValid("a", requireModifier: true))
        #expect(!KeyTrigger.isValid("backquote", requireModifier: true))
        #expect(KeyTrigger.isValid("alt+backquote", requireModifier: true))
        #expect(ManagedGlobalAction.toggleQuickTerminal.keybindValue(trigger: "cmd+backquote")
                == "global:cmd+backquote=toggle_quick_terminal")
        #expect(ManagedGlobalAction.newWindow.keybindValue(trigger: "x") == nil)
    }

    @Test func workspaceShortcutsNeedCommand() {
        #expect(KeyTrigger.isValidWorkspaceShortcut("cmd+shift+1"))
        #expect(KeyTrigger.isValidWorkspaceShortcut("cmd+backquote"))
        #expect(!KeyTrigger.isValidWorkspaceShortcut("ctrl+1"))
        #expect(!KeyTrigger.isValidWorkspaceShortcut("f5"))
    }

    @Test func displayString() {
        #expect(KeyTrigger.displayString("cmd+shift+backquote") == "⇧⌘`")
        #expect(KeyTrigger.displayString("ctrl+alt+k") == "⌃⌥K")
        #expect(KeyTrigger.displayString("f5") == "F5")
    }
}

struct SettingsValidatorTests {
    private func ok(_ key: String, _ value: String) -> String? {
        try? SettingsValidator.validate(key: key, value: value).get()
    }

    @Test func enumsAgainstAllowedSet() {
        #expect(ok("quick-terminal-position", "right") == "right")
        #expect(ok("quick-terminal-position", " left ") == "left")
        #expect(ok("quick-terminal-position", "middle") == nil)
        #expect(ok("quick-terminal-animation-easing", "ease-in-out") == "ease-in-out")
        #expect(ok("macos-titlebar-style", "Tabs") == nil)
        #expect(ok("confirm-close-surface", "always") == "always")
        #expect(ok("slimer-status-bar", "hidden") == "hidden")
        #expect(ok("quick-terminal-autohide", "yes") == nil)
        #expect(ok("quick-terminal-autohide", "false") == "false")
    }

    @Test func unknownKeysAreRejected() {
        #expect(ok("command", "/bin/sh") == nil)
        #expect(ok("config-file", "/tmp/x") == nil)
    }

    @Test func numbersAreRanged() {
        #expect(ok("quick-terminal-animation-duration", "0.25") == "0.25")
        #expect(ok("quick-terminal-animation-duration", "1") == "1")
        #expect(ok("quick-terminal-animation-duration", "1.01") == nil)
        #expect(ok("quick-terminal-animation-duration", "-0.1") == nil)
        #expect(ok("background-opacity", "0.850") == "0.85")
        #expect(ok("font-size", "13.5") == "13.5")
        #expect(ok("font-size", "2") == nil)
        for bad in ["nan", "inf", "1e2", "0x10", "1,5", "", "1.2.3", "--1"] {
            #expect(ok("font-size", bad) == nil, "\(bad)")
        }
    }

    @Test func formatIsPOSIXAndShort() {
        #expect(SettingsValidator.format(0.2) == "0.2")
        #expect(SettingsValidator.format(14) == "14")
        #expect(SettingsValidator.format(0.1234) == "0.123")
        #expect(SettingsValidator.format(-0.0001) == "0")
    }

    @Test func fontFamily() {
        #expect(ok("font-family", "JetBrains Mono") == "JetBrains Mono")
        for bad in ["", "Mono\nkeybind = x", "Mono # comment", "\"Quoted\"", "Bad\u{7}", String(repeating: "a", count: 129)] {
            #expect(ok("font-family", bad) == nil, "\(bad.debugDescription)")
        }
    }

    @Test func themeNames() {
        #expect(ok("theme", "Catppuccin Mocha") == "Catppuccin Mocha")
        #expect(ok("theme", "light:Rose Pine Dawn,dark:Rose Pine") == "light:Rose Pine Dawn,dark:Rose Pine")
        for bad in ["../evil", "/abs/path", "~/x", ".hidden", "a,b", "light:/x,dark:y", "a:b", "x\ny", ""] {
            #expect(ok("theme", bad) == nil, "\(bad)")
        }
    }

    @Test func quickTerminalSize() {
        #expect(ok("quick-terminal-size", "40%") == "40%")
        #expect(ok("quick-terminal-size", "40%,800px") == "40%,800px")
        #expect(ok("quick-terminal-size", "33.50%") == "33.5%")
        for bad in ["40", "0%", "101%", "0px", "20000px", "40%,50%,60%", "%", "px", "40 %x"] {
            #expect(ok("quick-terminal-size", bad) == nil, "\(bad)")
        }
    }

    @Test func backgroundBlur() {
        #expect(ok("background-blur", "true") == "true")
        #expect(ok("background-blur", "20") == "20")
        #expect(ok("background-blur", "macos-glass-clear") == "macos-glass-clear")
        #expect(ok("background-blur", "101") == nil)
        #expect(ok("background-blur", "-1") == nil)
    }

    @Test func keybindsOnlyFromRecorderGrammar() {
        #expect(ok("keybind", "global:cmd+backquote=toggle_quick_terminal") == "global:cmd+backquote=toggle_quick_terminal")
        #expect(ok("keybind", "global:cmd+backquote=unbind") == "global:cmd+backquote=unbind")
        #expect(ok("keybind", "cmd+backquote=unbind") == "cmd+backquote=unbind")
        for bad in [
            "cmd+backquote=toggle_quick_terminal",          // not global
            "global:cmd+backquote=text:rm -rf ~",           // unmanaged action
            "global:a=toggle_quick_terminal",               // no modifier
            "global:super+grave_accent=new_window",         // outside grammar
            "all:global:cmd+k=new_window",                  // other prefixes
            "global:cmd+k=new_window\nkeybind = x=y",       // newline
        ] {
            #expect(ok("keybind", bad) == nil, "\(bad)")
        }
    }

    @Test func neverAcceptsLineBreaksForAnyKey() {
        for (key, _) in SettingsKeySpec.all {
            #expect(ok(key, "true\nx") == nil, "\(key)")
            #expect(ok(key, "1\u{2028}") == nil, "\(key)")
        }
    }
}

struct GlobalKeybindPlannerTests {
    private let begin = GhosttyConfigWriter.beginMarker
    private let end = GhosttyConfigWriter.endMarker

    @Test func setWithoutUserBindings() throws {
        let plan = GlobalKeybindPlanner.plan(states: [.toggleQuickTerminal: .set("cmd+backquote")], userBindings: [])
        #expect(plan.values == ["global:cmd+backquote=toggle_quick_terminal"])
        #expect(plan.leftActive.isEmpty)
    }

    @Test func unbindsUsersOldTriggerBeforeBinding() throws {
        let text = "keybind = global:cmd+grave_accent=toggle_quick_terminal\nkeybind = global:shift+cmd+k=toggle_quick_terminal\n"
        let users = try GlobalKeybindPlanner.userBindings(in: text)
        #expect(users.map(\.trigger) == ["cmd+grave_accent", "cmd+shift+k"])
        let plan = GlobalKeybindPlanner.plan(states: [.toggleQuickTerminal: .set("cmd+f1")], userBindings: users)
        #expect(plan.values == ["global:cmd+shift+k=unbind", "global:cmd+f1=toggle_quick_terminal"])
        // `grave_accent` isn't in the recorder grammar, so it is reported, not echoed.
        #expect(plan.leftActive.map(\.line) == [1])
    }

    @Test func disabledUnbindsAllAndRoundTrips() throws {
        let text = "keybind = global:cmd+backquote=toggle_quick_terminal\n"
        let users = try GlobalKeybindPlanner.userBindings(in: text)
        let plan = GlobalKeybindPlanner.plan(states: [.toggleQuickTerminal: .disabled], userBindings: users)
        #expect(plan.values == ["global:cmd+backquote=unbind"])

        let states = GlobalKeybindPlanner.states(managedValues: plan.values, userBindings: users)
        #expect(states[.toggleQuickTerminal] == .disabled)
        #expect(states[.newWindow] == .unmanaged)
    }

    @Test func sameTriggerNeedsNoUnbind() throws {
        let users = try GlobalKeybindPlanner.userBindings(in: "keybind = global:cmd+backquote=toggle_quick_terminal\n")
        let plan = GlobalKeybindPlanner.plan(states: [.toggleQuickTerminal: .set("cmd+backquote")], userBindings: users)
        #expect(plan.values == ["global:cmd+backquote=toggle_quick_terminal"])
    }

    @Test func reusedTriggerIsNotUnbound() throws {
        let users = try GlobalKeybindPlanner.userBindings(in: "keybind = global:cmd+backquote=toggle_quick_terminal\n")
        let plan = GlobalKeybindPlanner.plan(
            states: [.toggleQuickTerminal: .set("cmd+f1"), .newWindow: .set("cmd+backquote")],
            userBindings: users
        )
        #expect(plan.values == ["global:cmd+f1=toggle_quick_terminal", "global:cmd+backquote=new_window"])
    }

    @Test func bindingsAfterBlockCantBeUnbound() throws {
        let text = "\(begin)\n\(end)\nkeybind = global:cmd+k=new_window\n"
        let users = try GlobalKeybindPlanner.userBindings(in: text)
        #expect(users.first?.afterBlock == true)
        let plan = GlobalKeybindPlanner.plan(states: [.newWindow: .set("cmd+j")], userBindings: users)
        #expect(plan.values == ["global:cmd+j=new_window"])
        #expect(plan.leftActive.count == 1)
    }

    @Test func nonGlobalUserBindingsAreIgnored() throws {
        let users = try GlobalKeybindPlanner.userBindings(in: "keybind = cmd+n=new_window\n")
        #expect(users.isEmpty)
    }

    @Test func plannedValuesPassValidationAndWriter() throws {
        let users = try GlobalKeybindPlanner.userBindings(in: "keybind = global:alt+space=toggle_command_palette\n")
        let plan = GlobalKeybindPlanner.plan(
            states: [.toggleCommandPalette: .set("cmd+alt+p"), .newWindow: .set("cmd+shift+n")],
            userBindings: users
        )
        for value in plan.values {
            #expect((try? SettingsValidator.validate(key: "keybind", value: value).get()) == value)
        }
        let out = try GhosttyConfigWriter.render(text: "", entries: [.init("keybind", plan.values)])
        #expect(out.contains("keybind = global:alt+space=unbind\n"))
    }
}
