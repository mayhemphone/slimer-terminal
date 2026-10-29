//! slimer: "is the shell sitting at an empty primary prompt?"
//!
//! The macOS status bar and Workspace features only press Enter for the user
//! (after an explicit click) when this returns true. It relies entirely on
//! OSC 133 shell integration and errs on the side of `false`: anything it
//! cannot positively identify as an empty primary prompt input is "busy".
//!
//! Read-only over existing terminal state; callers hold the terminal lock.
const std = @import("std");
const terminal = @import("../terminal/main.zig");

const Terminal = terminal.Terminal;
const Pin = terminal.Pin;

/// How far we look above and below the cursor for the prompt's rows. Prompts
/// taller than this are treated as not idle.
const max_rows = 64;

/// True only if all of the following hold:
///
///   - The primary screen is active (no full-screen program).
///   - The cursor is in a prompt input area (OSC 133 B/I seen and no
///     OSC 133 C since), so the shell is reading a command line.
///   - Walking up from the cursor row we reach a row that started a primary
///     prompt (OSC 133 A / P with k=i or k=r) before finding any input text.
///     A secondary/continuation prompt (PS2) always has the earlier part of
///     the command above it, so it fails this check.
///   - No cell from that primary prompt row through the cursor row, nor in
///     rows below the cursor that continue the input (soft-wrapped or marked
///     as prompt rows), holds text that is not prompt text.
pub fn idlePromptEmpty(t: *const Terminal) bool {
    if (t.screens.active_key == .alternate) return false;

    const screen = t.screens.active;
    const cursor = &screen.cursor;
    if (cursor.semantic_content != .input) return false;
    const cursor_pin: Pin = cursor.page_pin.*;

    // From the cursor row up to (and including) the primary prompt row.
    var pin = cursor_pin;
    var found_primary = false;
    var rows: usize = 0;
    while (rows < max_rows) : (rows += 1) {
        if (!rowHasOnlyPromptText(pin)) return false;
        if (pin.rowAndCell().row.semantic_prompt == .prompt) {
            found_primary = true;
            break;
        }
        pin = pin.up(1) orelse break;
    }
    if (!found_primary) return false;

    // Rows below the cursor that are still part of this input.
    var below = cursor_pin;
    rows = 0;
    while (rows < max_rows) : (rows += 1) {
        below = below.down(1) orelse break;
        const row = below.rowAndCell().row;
        if (!row.wrap_continuation and row.semantic_prompt == .none) break;
        if (!rowHasOnlyPromptText(below)) return false;
    }

    return true;
}

/// True if every cell in the row with text is a prompt cell.
fn rowHasOnlyPromptText(pin: Pin) bool {
    const rac = pin.rowAndCell();
    const cells = pin.node.page().getCells(rac.row);
    for (cells) |cell| {
        if (cell.semantic_content == .prompt) continue;
        if (cell.hasText()) return false;
    }
    return true;
}

const testing = std.testing;

fn printStr(t: *Terminal, s: []const u8) !void {
    for (s) |c| try t.print(c);
}

fn newLine(t: *Terminal) !void {
    t.carriageReturn();
    try t.linefeed();
}

test "slimer prompt: no shell integration is never idle" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try printStr(&t, "$ ");
    try testing.expect(!idlePromptEmpty(&t));
}

test "slimer prompt: empty primary prompt is idle" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try printStr(&t, "user@host $ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expect(idlePromptEmpty(&t));
}

test "slimer prompt: typed input is not idle" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try printStr(&t, "$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try printStr(&t, "rm -rf");
    try testing.expect(!idlePromptEmpty(&t));

    // Cursor moved back to the start of the input: text after it still counts.
    t.setCursorPos(1, 3);
    try testing.expect(!idlePromptEmpty(&t));
}

test "slimer prompt: prompt only before input start" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try printStr(&t, "$ ");
    // Prompt drawn but no OSC 133 B yet: we cannot tell prompt from input.
    try testing.expect(!idlePromptEmpty(&t));
}

test "slimer prompt: running command is not idle" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try printStr(&t, "$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try printStr(&t, "sleep 5");
    try t.semanticPrompt(.init(.end_input_start_output));
    try newLine(&t);
    try testing.expect(!idlePromptEmpty(&t));
}

test "slimer prompt: multi-line primary prompt is idle" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try printStr(&t, "~/Dev main");
    try newLine(&t);
    try t.semanticPrompt(.{ .action = .prompt_start, .options_unvalidated = "k=s" });
    try printStr(&t, "> ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expect(idlePromptEmpty(&t));
}

test "slimer prompt: continuation prompt after input is not idle" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try printStr(&t, "$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try printStr(&t, "echo \"");
    try newLine(&t);
    try t.semanticPrompt(.{ .action = .prompt_start, .options_unvalidated = "k=c" });
    try printStr(&t, "> ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expect(!idlePromptEmpty(&t));
}

test "slimer prompt: alternate screen is not idle" {
    var t = try Terminal.init(testing.io, testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.semanticPrompt(.init(.fresh_line_new_prompt));
    try printStr(&t, "$ ");
    try t.semanticPrompt(.init(.end_prompt_start_input));
    try testing.expect(idlePromptEmpty(&t));
    try t.switchScreenMode(.@"1049", true);
    try testing.expect(!idlePromptEmpty(&t));
}
