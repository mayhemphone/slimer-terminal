//! Slimer autocomplete: the report gate, surface-side state and the
//! accept wire format.
//!
//! The OSC 7704 parser lives in the terminal module
//! (`terminal/osc/parsers/autocomplete_buffer.zig`). This module owns
//! everything after the parser: the IO-thread gate (`Gate`), the message
//! payload that crosses from the IO thread to the surface (`Update`), the
//! surface-owned copy of the last accepted buffer (`State`), and the
//! validation and encoding of text the app sends back to the shell.
//!
//! Security model, in one place (see docs/slimer/AUTOCOMPLETE.md):
//!
//! - The reported buffer is untrusted data. It is length-capped by the
//!   parser and gated on the IO thread, in stream order: the report must
//!   carry the per-surface secret (`n=`, the shell got it through
//!   `SLIMER_AUTOCOMPLETE_TOKEN` and unset it), the terminal must be in
//!   the prompt-input state on the primary screen, and the rate limit
//!   must hold. It is stored as bytes and only read back through the C
//!   API. Nothing here interprets or executes it.
//! - Accepting is gated too (`Surface.autocompleteAccept`): the state must
//!   be live, the generation must match the popup's, the terminal must
//!   still be at prompt input, and the pty's foreground process group must
//!   be the shell that reported (`p=`). Enter, ^C, ^D and ^Z typed by the
//!   user clear the state synchronously.
//! - Text accepted from the app is rejected, not stripped, if it contains
//!   control characters, invalid UTF-8, or code points in the Unicode
//!   categories Cf, Zl, Zp, Cs, Cn or Co, or noncharacters, or if it is
//!   longer than `max_accept_bytes`. On the wire every byte is hex
//!   encoded, so if the shell widget is not reached the bytes that leak
//!   as keystrokes are only `%`, digits and `A`-`F`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const uucode = @import("uucode");

pub const Engine = @import("Engine.zig");
pub const Spec = @import("Spec.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const History = @import("History.zig");
pub const Worker = @import("Worker.zig").Worker;
pub const OwnedResult = @import("Worker.zig").OwnedResult;

/// Glue between the core surface and the shared engine. Only analyzed
/// when referenced (it pulls in global state).
pub const glue = @import("glue.zig");

/// The longest decoded buffer the surface stores. Matches the parser's
/// `max_buffer_bytes` and the shell-side truncation cap.
pub const max_buffer_bytes = 4096;

/// The longest replacement text the app may send to the shell.
pub const max_accept_bytes = 4096;

/// How many accepted reports a surface takes per second before dropping.
pub const rate_limit_per_second = 200;

/// Length of the per-surface secret in hex characters (128 bits).
pub const token_hex_len = 32;

/// Environment variable that carries the secret to the shell.
pub const token_env = "SLIMER_AUTOCOMPLETE_TOKEN";

/// Sync with `GHOSTTY_AUTOCOMPLETE_KEYMAP_*` in ghostty.h.
pub const Keymap = enum(u8) {
    emacs = 0,
    viins = 1,
    vicmd = 2,
    other = 3,

    pub fn fromName(name: []const u8) Keymap {
        return std.meta.stringToEnum(Keymap, name) orelse .other;
    }
};

/// A per-surface secret the shell must echo in every report.
pub const Token = struct {
    hex: [token_hex_len]u8,

    /// A fresh secret from the OS's secure random source, or null if
    /// that isn't available (the caller then leaves autocomplete off).
    pub fn random(io: std.Io) ?Token {
        var bytes: [token_hex_len / 2]u8 = undefined;
        io.randomSecure(&bytes) catch return null;
        var t: Token = undefined;
        _ = std.fmt.bufPrint(&t.hex, "{x}", .{&bytes}) catch unreachable;
        return t;
    }

    /// Constant-time comparison against a reported value.
    pub fn matches(self: *const Token, reported: []const u8) bool {
        if (reported.len != token_hex_len) return false;
        var diff: u8 = 0;
        for (self.hex, reported[0..token_hex_len]) |a, b| diff |= a ^ b;
        return diff == 0;
    }
};

/// The IO-thread gate for OSC 7704 reports. Owned by the stream handler,
/// which processes output in order and holds the terminal lock, so the
/// prompt-input check sees exactly the state the report was written in.
pub const Gate = struct {
    /// The surface's secret. Null means autocomplete reports are never
    /// accepted (no token was handed to the shell).
    token: ?Token = null,

    /// Fixed-window rate limiter.
    window_start: ?std.Io.Timestamp = null,
    window_count: u32 = 0,

    /// True if a report was forwarded since the last deactivate, so
    /// prompt marks only post a deactivate when something is live.
    live: bool = false,

    /// The shell left the line editor (`d=1`): refuse reports until the
    /// next line starts (OSC 133 A/B, or a report with `i=1`).
    ended: bool = false,

    /// A line started and no report was forwarded since: the next
    /// forwarded report is marked `line_start`.
    fresh: bool = false,

    pub const Verdict = enum { accept, bad_token, not_at_input, rate_limited, line_ended };

    /// A new line is being edited (133 A/B, or `i=1` from zle line-init).
    pub fn markLineStart(self: *Gate) void {
        self.ended = false;
        self.fresh = true;
    }

    /// The shell left the line editor (`d=1`).
    pub fn markLineEnd(self: *Gate) void {
        self.ended = true;
        self.live = false;
    }

    /// Whether the report being forwarded is the first of its line.
    pub fn takeFresh(self: *Gate) bool {
        const f = self.fresh;
        self.fresh = false;
        return f;
    }

    /// Terminal facts the caller reads under the terminal lock.
    pub const TerminalState = struct {
        primary_screen: bool,
        shell_integration_seen: bool,
        at_input: bool,
    };

    pub fn check(
        self: *Gate,
        nonce: []const u8,
        line_init: bool,
        term: TerminalState,
        now: std.Io.Timestamp,
    ) Verdict {
        const token = &(self.token orelse return .bad_token);
        if (!token.matches(nonce)) return .bad_token;
        if (line_init) self.markLineStart();
        if (self.ended) return .line_ended;
        if (!term.primary_screen or !term.shell_integration_seen or !term.at_input)
            return .not_at_input;
        if (!self.admit(now)) return .rate_limited;
        return .accept;
    }

    /// Returns true if a report arriving at `now` is within the rate
    /// limit and counts it. A fixed one-second window is enough here: the
    /// goal is to bound work from a hostile or runaway shell, not to
    /// shape traffic precisely.
    pub fn admit(self: *Gate, now: std.Io.Timestamp) bool {
        if (self.window_start) |start| {
            if (start.durationTo(now).toMilliseconds() < 1000) {
                if (self.window_count >= rate_limit_per_second) return false;
                self.window_count += 1;
                return true;
            }
        }
        self.window_start = now;
        self.window_count = 1;
        return true;
    }
};

/// The payload of the `autocomplete_buffer` surface message. Built on the
/// IO thread after the gate passes; the surface takes ownership of the
/// buffer (`State.take`) or frees it (`deinit`).
pub const Update = struct {
    alloc: Allocator,
    /// Percent-decoded buffer, owned. Empty for a deactivate.
    buffer: []u8,
    cursor: u32,
    keymap: Keymap,
    truncated: bool,
    /// The shell's process group (`p=`), compared with the pty's
    /// foreground group before accepting.
    pgid: u32,
    /// Set for an update that only ends the live state.
    deactivate: ?Deactivate = null,

    /// The first report of a new line (see `Gate.fresh`). Clears the
    /// surface's "line ended" latch and drops a stashed line that never ran.
    line_start: bool = false,

    /// For a `line_finish` deactivate: the shell's verdict on adding the
    /// line to history (`h=`). `true`: `buffer` is the full command line
    /// to record. `false`: record nothing (HISTORY_IGNORE, incognito).
    /// null: the shell didn't say; record the last reported buffer.
    history: ?bool = null,

    pub const Deactivate = enum {
        /// The shell left the line editor (zle `line-finish`, `d=1`): the
        /// line may be about to run, so keep it until OSC 133 C records
        /// it to history.
        line_finish,
        /// A prompt mark (133 A/D) or the alternate screen: forget
        /// everything, including a line waiting to be recorded.
        reset,
    };

    pub fn init(
        alloc: Allocator,
        buffer: []const u8,
        cursor: u32,
        keymap_name: []const u8,
        truncated: bool,
        pgid: u32,
    ) Allocator.Error!Update {
        return .{
            .alloc = alloc,
            .buffer = try alloc.dupe(u8, buffer),
            .cursor = cursor,
            .keymap = .fromName(keymap_name),
            .truncated = truncated,
            .pgid = pgid,
        };
    }

    /// An update that only ends the surface state.
    pub fn deactivation(alloc: Allocator, kind: Deactivate) Update {
        return .{
            .alloc = alloc,
            .buffer = &.{},
            .cursor = 0,
            .keymap = .other,
            .truncated = false,
            .pgid = 0,
            .deactivate = kind,
        };
    }

    pub fn deinit(self: *const Update) void {
        self.alloc.free(self.buffer);
    }
};

/// Surface-owned autocomplete state. The surface is the only writer and
/// readers go through the surface (the app thread), so no locking.
pub const State = struct {
    /// The last accepted buffer, owned. Valid until the next `take` or
    /// `clear`, which is what the C API documents to callers.
    buffer: []u8 = &.{},
    cursor: u32 = 0,
    keymap: Keymap = .other,
    pgid: u32 = 0,

    /// The shell truncated the buffer; never recorded to history.
    truncated: bool = false,

    /// The line the user submitted (stashed on Enter or zle line-finish),
    /// owned, waiting for OSC 133 C to record it to history. Empty when
    /// none. Never a truncated buffer.
    pending: []u8 = &.{},

    /// The latest query result from the worker, owned. Only used while its
    /// generation is the current one.
    result: ?*OwnedResult = null,

    /// The generation a query was last requested for, so repeated polls
    /// for the same buffer don't queue more work.
    requested: u64 = 0,

    /// Set when the line was submitted or interrupted (Enter, ^C, ^D, ^Z,
    /// text with CR/LF, zle line-finish). Reports are ignored until the
    /// next line starts, so a late report can't revive a stale line.
    line_ended: bool = false,

    /// True between a `take` and the next `clear`. The C API reports
    /// false when nothing is live so the app can hide its popup.
    active: bool = false,

    /// Bumped on every change so the app can tell stale popups apart.
    generation: u64 = 0,

    pub fn deinit(self: *State, alloc: Allocator) void {
        alloc.free(self.buffer);
        alloc.free(self.pending);
        if (self.result) |r| r.destroy();
        self.* = .{};
    }

    /// Replace the stored result.
    pub fn setResult(self: *State, r: *OwnedResult) void {
        if (self.result) |old| old.destroy();
        self.result = r;
    }

    /// Apply a non-deactivate update, honoring the "line ended" latch.
    /// Returns false (and frees the update) if it was ignored.
    pub fn accept(self: *State, alloc: Allocator, update: Update) bool {
        if (update.line_start) {
            self.line_ended = false;
            // The stashed line never reached 133 C: it didn't run.
            alloc.free(self.pending);
            self.pending = &.{};
        } else if (self.line_ended) {
            update.deinit();
            return false;
        }
        self.take(alloc, update);
        return true;
    }

    /// Handle zle line-finish (`d=1`): end the live state, then apply the
    /// shell's history verdict to the stashed line.
    pub fn lineFinish(self: *State, alloc: Allocator, update: Update) void {
        self.stash(alloc);
        self.line_ended = true;
        if (update.history) |record| {
            alloc.free(self.pending);
            self.pending = &.{};
            if (record and !update.truncated and update.buffer.len > 0) {
                self.pending = update.buffer;
                return; // ownership moved
            }
        }
        update.deinit();
    }

    /// Take ownership of `update`'s buffer and bump the generation. The
    /// update must have been allocated with `alloc` and must not be
    /// freed afterwards. The cursor is clamped to the buffer.
    pub fn take(self: *State, alloc: Allocator, update: Update) void {
        std.debug.assert(update.deactivate == null);
        alloc.free(self.buffer);
        self.buffer = update.buffer;
        self.cursor = @intCast(@min(update.cursor, self.buffer.len));
        self.keymap = update.keymap;
        self.truncated = update.truncated;
        self.pgid = update.pgid;
        self.active = true;
        self.generation +%= 1;
    }

    /// End the live state but keep the line as `pending` for history.
    /// Does nothing if nothing is live.
    pub fn stash(self: *State, alloc: Allocator) void {
        if (!self.active) return;
        alloc.free(self.pending);
        if (self.truncated) {
            alloc.free(self.buffer);
            self.pending = &.{};
        } else {
            self.pending = self.buffer;
        }
        self.buffer = &.{};
        self.cursor = 0;
        self.truncated = false;
        self.pgid = 0;
        self.active = false;
        self.generation +%= 1;
    }

    /// Take ownership of the pending line, if any.
    pub fn takePending(self: *State) []u8 {
        const p = self.pending;
        self.pending = &.{};
        return p;
    }

    /// Forget the buffer and any pending line and bump the generation.
    /// Used on dismiss and whenever the popup must go away.
    pub fn clear(self: *State, alloc: Allocator) void {
        alloc.free(self.pending);
        self.pending = &.{};
        if (self.result) |r| r.destroy();
        self.result = null;
        alloc.free(self.buffer);
        self.buffer = &.{};
        self.cursor = 0;
        self.truncated = false;
        self.pgid = 0;
        self.active = false;
        self.generation +%= 1;
    }
};

/// True if a command line starts PowerShell (`pwsh`, `powershell`, with
/// or without `.exe` or a path), which loads the Slimer module from the
/// user's profile and so needs the autocomplete secret.
pub fn isPowerShell(command_line: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, command_line, " \t");
    const first = words.next() orelse return false;
    const slash = std.mem.lastIndexOfAny(u8, first, "/\\") orelse return isPowerShellName(first);
    return isPowerShellName(first[slash + 1 ..]);
}

fn isPowerShellName(name: []const u8) bool {
    const base = if (std.ascii.endsWithIgnoreCase(name, ".exe")) name[0 .. name.len - 4] else name;
    return std.ascii.eqlIgnoreCase(base, "pwsh") or std.ascii.eqlIgnoreCase(base, "powershell");
}

test "autocomplete: PowerShell detection" {
    const testing = std.testing;
    try testing.expect(isPowerShell("pwsh"));
    try testing.expect(isPowerShell("/usr/local/bin/pwsh -NoLogo"));
    try testing.expect(isPowerShell("C:\\PowerShell\\7\\pwsh.exe"));
    try testing.expect(isPowerShell("powershell.exe"));
    try testing.expect(!isPowerShell("/bin/zsh"));
    try testing.expect(!isPowerShell("bash -l"));
    try testing.expect(!isPowerShell(""));
}

/// Returns true if text sent to the pty (typed text, a `text:` binding, a
/// paste) contains CR or LF, which submits the line.
pub fn submitsLine(text: []const u8) bool {
    return std.mem.indexOfAny(u8, text, "\r\n") != null;
}

/// Returns true if the bytes a key press writes to the pty end or
/// interrupt the line being edited: CR, LF, ^C, ^D or ^Z anywhere in the
/// encoding. The surface clears the state synchronously on these so a
/// fast Enter-then-Tab can't accept into the command that just started.
pub fn endsLine(encoded: []const u8) bool {
    for (encoded) |c| switch (c) {
        '\r', '\n', 0x03, 0x04, 0x1a => return true,
        else => {},
    };
    return false;
}

/// Returns true if `text` may be sent to the shell as a replacement.
/// Rejects anything that could act as input other than plain text or
/// disguise what gets inserted: C0 and C1 controls (so no newline, ESC,
/// BEL, tab), DEL, invalid UTF-8, the Unicode categories Cf (format:
/// bidi controls, zero-width characters), Zl, Zp, Cs, Cn (unassigned) and
/// Co (private use), and noncharacters.
pub fn isSafeAcceptText(text: []const u8) bool {
    if (text.len == 0 or text.len > max_accept_bytes) return false;

    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (!isSafeCodepoint(cp)) return false;
    }
    return true;
}

fn isSafeCodepoint(cp: u21) bool {
    switch (cp) {
        0x00...0x1F, 0x7F...0x9F => return false,
        // Noncharacters: U+FDD0..U+FDEF and the last two of every plane.
        0xFDD0...0xFDEF => return false,
        else => {},
    }
    if ((cp & 0xFFFE) == 0xFFFE) return false;
    // ASCII printable is always fine; skip the table lookup.
    if (cp < 0x80) return true;
    return switch (uucode.get(.general_category, cp)) {
        .other_format,
        .separator_line,
        .separator_paragraph,
        .other_surrogate,
        .other_not_assigned,
        .other_private_use,
        => false,
        else => true,
    };
}

/// Returns true if `c` must be percent-encoded in a buffer report.
/// Mirrors the shell script's encoder exactly.
pub fn needsPercent(c: u8) bool {
    return switch (c) {
        '%', ';', 0x00...0x1F, 0x7F => true,
        else => false,
    };
}

/// Percent-encode `text` the way the shell does: `%`, `;`, C0 controls
/// and DEL become `%XX` with uppercase hex; everything else is raw. Used
/// for the history log.
pub fn percentEncode(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        if (needsPercent(c)) {
            try writer.print("%{X:0>2}", .{c});
        } else {
            try writer.writeByte(c);
        }
    }
}

/// Hex-encode every byte as `%XX` (uppercase). Used for the accept
/// payload so stray bytes that reach zle as keystrokes are harmless.
pub fn percentEncodeAll(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| try writer.print("%{X:0>2}", .{c});
}

/// What an accepted completion replaces in the shell.
pub const AcceptMode = enum {
    /// The current token (`CSI 7705 ~`). The widget finds the token and
    /// shell-quotes the text.
    token,
    /// The whole line (`CSI 7706 ~`), for history suggestions. The widget
    /// inserts the text unquoted, and only if the cursor is at the end
    /// and the current line is a prefix of the text.
    line,

    fn csi(self: AcceptMode) []const u8 {
        return switch (self) {
            .token => "\x1b[7705~",
            .line => "\x1b[7706~",
        };
    }
};

/// Write the accept sequence for `text`: `CSI 7705 ~` (or 7706 for a
/// line), every byte of the text as `%XX`, then BEL. The shell widget
/// bound to the CSI reads up to the BEL. The caller must have checked
/// the text with `isSafeAcceptText`.
pub fn writeAcceptSequence(writer: *std.Io.Writer, text: []const u8, mode: AcceptMode) std.Io.Writer.Error!void {
    std.debug.assert(isSafeAcceptText(text));
    try writer.writeAll(mode.csi());
    try percentEncodeAll(writer, text);
    try writer.writeByte(0x07);
}

/// Upper bound on the encoded size of an accept sequence for `len`
/// bytes of text.
pub fn acceptSequenceCapacity(len: usize) usize {
    return "\x1b[7705~".len + len * 3 + 1;
}

/// Sync with `ghostty_autocomplete_item_s` in ghostty.h. Strings are
/// not NUL-terminated.
pub const CItem = extern struct {
    text: [*]const u8 = "",
    text_len: usize = 0,
    display: [*]const u8 = "",
    display_len: usize = 0,
    description: [*]const u8 = "",
    description_len: usize = 0,
    kind: u8 = 0,
    dangerous: bool = false,
    /// Bytes at the start of `display` that matched the typed prefix.
    match_len: u32 = 0,
};

/// Sync with `ghostty_autocomplete_result_s` in ghostty.h.
pub const CResult = extern struct {
    items: [Engine.max_items]CItem = @splat(.{}),
    count: usize = 0,
    /// The replaced token, in characters (code points) like the 6A
    /// cursor, and its display width in terminal cells.
    replace_start: u32 = 0,
    replace_len: u32 = 0,
    replace_cols: u32 = 0,
    generation: u64 = 0,
    /// No result yet for this generation: a query is running. Keep the
    /// current popup as is and wait for the next update.
    pending: bool = false,
};

test {
    _ = Engine;
    _ = Spec;
    _ = Tokenizer;
    _ = History;
    _ = @import("Fs.zig");
    _ = @import("Generators.zig");
    _ = @import("Rank.zig");
    _ = @import("Worker.zig");
}

test "autocomplete: keymap names" {
    const testing = std.testing;
    try testing.expectEqual(Keymap.emacs, Keymap.fromName("emacs"));
    try testing.expectEqual(Keymap.viins, Keymap.fromName("viins"));
    try testing.expectEqual(Keymap.vicmd, Keymap.fromName("vicmd"));
    try testing.expectEqual(Keymap.other, Keymap.fromName("visual"));
    try testing.expectEqual(Keymap.other, Keymap.fromName(""));
}

test "autocomplete: state take, clamp, clear, generation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var state: State = .{};
    defer state.deinit(alloc);
    try testing.expectEqual(@as(u64, 0), state.generation);

    state.take(alloc, try Update.init(alloc, "git sta", 99, "emacs", false, 42));
    try testing.expectEqualStrings("git sta", state.buffer);
    try testing.expectEqual(@as(u32, 7), state.cursor);
    try testing.expectEqual(Keymap.emacs, state.keymap);
    try testing.expectEqual(@as(u32, 42), state.pgid);
    try testing.expect(state.active);
    try testing.expectEqual(@as(u64, 1), state.generation);

    state.take(alloc, try Update.init(alloc, "ls", 1, "vicmd", true, 42));
    try testing.expectEqualStrings("ls", state.buffer);
    try testing.expectEqual(@as(u32, 1), state.cursor);
    try testing.expect(state.truncated);
    try testing.expectEqual(@as(u64, 2), state.generation);

    state.clear(alloc);
    try testing.expectEqual(@as(usize, 0), state.buffer.len);
    try testing.expect(!state.active);
    try testing.expectEqual(@as(u32, 0), state.pgid);
    try testing.expectEqual(@as(u64, 3), state.generation);

    // A deactivation owns nothing.
    const d = Update.deactivation(alloc, .reset);
    d.deinit();
}

test "autocomplete: stash keeps the submitted line for history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var state: State = .{};
    defer state.deinit(alloc);

    state.take(alloc, try Update.init(alloc, "make test", 9, "emacs", false, 1));
    const gen = state.generation;
    state.stash(alloc);
    try testing.expect(!state.active);
    try testing.expect(state.generation != gen);
    try testing.expectEqualStrings("make test", state.pending);
    // A second stash with nothing live keeps the pending line.
    state.stash(alloc);
    try testing.expectEqualStrings("make test", state.pending);

    const line = state.takePending();
    defer alloc.free(line);
    try testing.expectEqualStrings("make test", line);
    try testing.expectEqual(@as(usize, 0), state.pending.len);

    // Truncated buffers are never stashed; clear drops a pending line.
    state.take(alloc, try Update.init(alloc, "x", 1, "emacs", true, 1));
    state.stash(alloc);
    try testing.expectEqual(@as(usize, 0), state.pending.len);
    state.take(alloc, try Update.init(alloc, "y", 1, "emacs", false, 1));
    state.stash(alloc);
    state.clear(alloc);
    try testing.expectEqual(@as(usize, 0), state.pending.len);
}

test "autocomplete: gate token, prompt state and rate limit" {
    const testing = std.testing;
    var gate: Gate = .{};
    const at_input: Gate.TerminalState = .{ .primary_screen = true, .shell_integration_seen = true, .at_input = true };
    const t0: std.Io.Timestamp = .{ .nanoseconds = 0 };

    // No token configured: nothing is accepted.
    try testing.expectEqual(Gate.Verdict.bad_token, gate.check("", false, at_input, t0));

    gate.token = Token.random(testing.io).?;
    const good = gate.token.?.hex;
    var bad = good;
    bad[5] ^= 1;
    try testing.expectEqual(Gate.Verdict.bad_token, gate.check(&bad, false, at_input, t0));
    try testing.expectEqual(Gate.Verdict.bad_token, gate.check(good[0..31], false, at_input, t0));
    try testing.expectEqual(Gate.Verdict.bad_token, gate.check("", false, at_input, t0));

    try testing.expectEqual(Gate.Verdict.not_at_input, gate.check(&good, false, .{ .primary_screen = false, .shell_integration_seen = true, .at_input = true }, t0));
    try testing.expectEqual(Gate.Verdict.not_at_input, gate.check(&good, false, .{ .primary_screen = true, .shell_integration_seen = false, .at_input = true }, t0));
    try testing.expectEqual(Gate.Verdict.not_at_input, gate.check(&good, false, .{ .primary_screen = true, .shell_integration_seen = true, .at_input = false }, t0));

    var i: usize = 0;
    while (i < rate_limit_per_second) : (i += 1) {
        try testing.expectEqual(Gate.Verdict.accept, gate.check(&good, false, at_input, t0));
    }
    // The 201st in the same second is dropped, as is one 999ms later.
    try testing.expectEqual(Gate.Verdict.rate_limited, gate.check(&good, false, at_input, t0));
    try testing.expect(!gate.admit(.{ .nanoseconds = 999 * std.time.ns_per_ms }));
    // A new window opens after a second.
    try testing.expect(gate.admit(.{ .nanoseconds = 1000 * std.time.ns_per_ms }));
}

test "autocomplete: gate refuses reports after line end until a line starts" {
    const testing = std.testing;
    var gate: Gate = .{ .token = Token.random(testing.io).? };
    const tok = gate.token.?.hex;
    const at_input: Gate.TerminalState = .{ .primary_screen = true, .shell_integration_seen = true, .at_input = true };
    const t0: std.Io.Timestamp = .{ .nanoseconds = 0 };

    gate.markLineStart();
    try testing.expectEqual(Gate.Verdict.accept, gate.check(&tok, false, at_input, t0));
    try testing.expect(gate.takeFresh());
    try testing.expectEqual(Gate.Verdict.accept, gate.check(&tok, false, at_input, t0));
    try testing.expect(!gate.takeFresh());

    gate.markLineEnd();
    try testing.expectEqual(Gate.Verdict.line_ended, gate.check(&tok, false, at_input, t0));
    // zle line-init (i=1) starts a new line.
    try testing.expectEqual(Gate.Verdict.accept, gate.check(&tok, true, at_input, t0));
    try testing.expect(gate.takeFresh());
    gate.markLineEnd();
    gate.markLineStart(); // 133 A/B
    try testing.expectEqual(Gate.Verdict.accept, gate.check(&tok, false, at_input, t0));
}

test "autocomplete: state latch, line start and history verdicts" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var state: State = .{};
    defer state.deinit(alloc);

    try testing.expect(state.accept(alloc, try Update.init(alloc, "make t", 6, "emacs", false, 1)));
    // Enter: stash and latch; later reports for the old line are ignored.
    state.stash(alloc);
    state.line_ended = true;
    try testing.expectEqualStrings("make t", state.pending);
    try testing.expect(!state.accept(alloc, try Update.init(alloc, "make te", 7, "emacs", false, 1)));
    try testing.expect(!state.active);

    // zle line-finish with the full multi-line command for history.
    var fin = Update.deactivation(alloc, .line_finish);
    fin.history = true;
    fin.buffer = try alloc.dupe(u8, "make t \\\n  V=1");
    state.lineFinish(alloc, fin);
    try testing.expectEqualStrings("make t \\\n  V=1", state.pending);

    // h=0 (HISTORY_IGNORE / incognito) drops it.
    var no = Update.deactivation(alloc, .line_finish);
    no.history = false;
    state.lineFinish(alloc, no);
    try testing.expectEqual(@as(usize, 0), state.pending.len);

    // ^C then a new line: the stashed line is dropped at line start.
    try testing.expect(!state.accept(alloc, try Update.init(alloc, "x", 1, "emacs", false, 1)));
    state.line_ended = false;
    try testing.expect(state.accept(alloc, try Update.init(alloc, "rm -rf", 6, "emacs", false, 1)));
    state.stash(alloc);
    state.line_ended = true;
    var next = try Update.init(alloc, "l", 1, "emacs", false, 1);
    next.line_start = true;
    try testing.expect(state.accept(alloc, next));
    try testing.expectEqual(@as(usize, 0), state.pending.len);
    try testing.expect(!state.line_ended);
    try testing.expectEqualStrings("l", state.buffer);
}

test "autocomplete: text that submits the line" {
    const testing = std.testing;
    try testing.expect(submitsLine("ls\n"));
    try testing.expect(submitsLine("a\rb"));
    try testing.expect(!submitsLine("ls -la"));
}

test "autocomplete: token is 128-bit lowercase hex and random" {
    const testing = std.testing;
    const a = Token.random(testing.io).?;
    const b = Token.random(testing.io).?;
    for (a.hex) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    try testing.expect(!std.mem.eql(u8, &a.hex, &b.hex));
    try testing.expect(a.matches(&a.hex));
}

test "autocomplete: keys that end the line" {
    const testing = std.testing;
    try testing.expect(endsLine("\r"));
    try testing.expect(endsLine("\n"));
    try testing.expect(endsLine("\x03"));
    try testing.expect(endsLine("\x04"));
    try testing.expect(endsLine("\x1a"));
    try testing.expect(endsLine("\x1b\r"));
    try testing.expect(!endsLine("a"));
    try testing.expect(!endsLine("\t"));
    try testing.expect(!endsLine("\x1b[A"));
}

test "autocomplete: accept text validation" {
    const testing = std.testing;

    try testing.expect(isSafeAcceptText("status"));
    try testing.expect(isSafeAcceptText("--all"));
    try testing.expect(isSafeAcceptText("my file.txt"));
    try testing.expect(isSafeAcceptText("ünïcödé/路径"));
    try testing.expect(isSafeAcceptText("a;b%c"));
    try testing.expect(isSafeAcceptText("emoji 🙂"));

    try testing.expect(!isSafeAcceptText(""));
    try testing.expect(!isSafeAcceptText("ls\n"));
    try testing.expect(!isSafeAcceptText("ls\r"));
    try testing.expect(!isSafeAcceptText("a\tb"));
    try testing.expect(!isSafeAcceptText("\x1b[31m"));
    try testing.expect(!isSafeAcceptText("\x07"));
    try testing.expect(!isSafeAcceptText("del\x7f"));
    try testing.expect(!isSafeAcceptText("\xc2\x85")); // C1 NEL
    try testing.expect(!isSafeAcceptText("\xff")); // invalid UTF-8
    try testing.expect(!isSafeAcceptText("\xed\xa0\x80")); // surrogate (invalid UTF-8)
    try testing.expect(!isSafeAcceptText("a\u{2028}b")); // Zl
    try testing.expect(!isSafeAcceptText("a\u{2029}b")); // Zp
    try testing.expect(!isSafeAcceptText("\u{202e}gnp.exe")); // Cf bidi
    try testing.expect(!isSafeAcceptText("\u{2066}x\u{2069}")); // Cf isolate
    try testing.expect(!isSafeAcceptText("a\u{200b}b")); // Cf zero width space
    try testing.expect(!isSafeAcceptText("a\u{feff}")); // Cf BOM
    try testing.expect(!isSafeAcceptText("a\u{e000}")); // Co
    try testing.expect(!isSafeAcceptText("a\u{10ffff}")); // noncharacter
    try testing.expect(!isSafeAcceptText("a\u{fdd0}")); // noncharacter
    try testing.expect(!isSafeAcceptText("a\u{0378}")); // Cn (unassigned)

    const big = try testing.allocator.alloc(u8, max_accept_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expect(!isSafeAcceptText(big));
    try testing.expect(isSafeAcceptText(big[0..max_accept_bytes]));
}

test "autocomplete: accept sequence encodes every byte" {
    const testing = std.testing;

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeAcceptSequence(&w, "a%; é#", .token);
    try testing.expectEqualStrings("\x1b[7705~%61%25%3B%20%C3%A9%23\x07", w.buffered());
    try testing.expect(acceptSequenceCapacity(7) >= w.buffered().len);

    // Only %, hex digits, the CSI and BEL ever appear.
    for (w.buffered()["\x1b[7705~".len .. w.buffered().len - 1]) |c| {
        try testing.expect(c == '%' or std.ascii.isDigit(c) or (c >= 'A' and c <= 'F'));
    }

    w = .fixed(&buf);
    try writeAcceptSequence(&w, "git push", .line);
    try testing.expectEqualStrings("\x1b[7706~%67%69%74%20%70%75%73%68\x07", w.buffered());
}

test "autocomplete: percent encode covers every byte the shell encodes" {
    const testing = std.testing;

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try percentEncode(&w, "\x00\x1f\x7f%;a");
    try testing.expectEqualStrings("%00%1F%7F%25%3Ba", w.buffered());
}
