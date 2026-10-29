//! Slimer autocomplete: surface-side state and the accept wire format.
//!
//! The OSC 7704 parser lives in the terminal module
//! (`terminal/osc/parsers/autocomplete_buffer.zig`). This module owns
//! everything after the parser: the message payload that crosses from the
//! IO thread to the surface, the surface-owned copy of the last accepted
//! buffer, the rate limiter, and the validation and encoding of text the
//! app sends back to the shell with `CSI 7705 ~`.
//!
//! Security model, in one place:
//!
//! - The reported buffer is untrusted data. It is length-capped by the
//!   parser, gated by the surface (shell integration seen, prompt input
//!   state, rate limit), stored as bytes, and only ever read back through
//!   the C API. Nothing here interprets or executes it.
//! - Text accepted from the app is rejected, not stripped, if it contains
//!   control characters, DEL, invalid UTF-8, C1 controls, U+2028/2029 or
//!   bidi overrides, or if it is longer than `max_accept_bytes`. The
//!   shell widget shell-quotes it again before inserting, and the widget
//!   computes the replaced range itself, so the terminal can never cause
//!   over-deletion or execution.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Engine = @import("Engine.zig");
pub const Spec = @import("Spec.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const History = @import("History.zig");

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

/// The payload of the `autocomplete_buffer` surface message. Built on the
/// IO thread from the parser's borrowed slices and freed by the surface.
pub const Update = struct {
    alloc: Allocator,
    /// Percent-decoded buffer, owned.
    buffer: []u8,
    cursor: u32,
    keymap: Keymap,
    truncated: bool,

    pub fn init(
        alloc: Allocator,
        buffer: []const u8,
        cursor: u32,
        keymap_name: []const u8,
        truncated: bool,
    ) Allocator.Error!Update {
        return .{
            .alloc = alloc,
            .buffer = try alloc.dupe(u8, buffer),
            .cursor = cursor,
            .keymap = .fromName(keymap_name),
            .truncated = truncated,
        };
    }

    pub fn deinit(self: *const Update) void {
        self.alloc.free(self.buffer);
    }
};

/// Surface-owned autocomplete state. The surface is the only writer and
/// readers go through the surface (the app thread), so no locking.
pub const State = struct {
    /// The last accepted buffer, owned. Valid until the next `set` or
    /// `clear`, which is what the C API documents to callers.
    buffer: []u8 = &.{},
    cursor: u32 = 0,
    keymap: Keymap = .other,

    /// The shell truncated the buffer; never recorded to history.
    truncated: bool = false,

    /// Strings of the last query result, owned by the surface until the
    /// next query (the engine's own scratch memory is shared).
    query_arena: ?std.heap.ArenaAllocator = null,

    /// True between a `set` and the next `clear`. The C API reports
    /// false when nothing is live so the app can hide its popup.
    active: bool = false,

    /// Bumped on every change so the app can tell stale popups apart.
    generation: u64 = 0,

    /// Fixed-window rate limiter.
    window_start: ?std.Io.Timestamp = null,
    window_count: u32 = 0,

    pub fn deinit(self: *State, alloc: Allocator) void {
        alloc.free(self.buffer);
        if (self.query_arena) |*a| a.deinit();
        self.* = .{};
    }

    /// The arena for a new query result, reset from the previous one.
    pub fn resetQueryArena(self: *State, alloc: Allocator) Allocator {
        if (self.query_arena) |*a| {
            _ = a.reset(.retain_capacity);
        } else {
            self.query_arena = .init(alloc);
        }
        return self.query_arena.?.allocator();
    }

    /// Returns true if a report arriving at `now` is within the rate
    /// limit and counts it. A fixed one-second window is enough here: the
    /// goal is to bound work from a hostile or runaway shell, not to
    /// shape traffic precisely.
    pub fn admit(self: *State, now: std.Io.Timestamp) bool {
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

    /// Copy `update` into the stored state and bump the generation. The
    /// update's own buffer is left for the caller to free. The cursor is
    /// clamped to the buffer.
    pub fn set(self: *State, alloc: Allocator, update: Update) Allocator.Error!void {
        const copy = try alloc.dupe(u8, update.buffer);
        alloc.free(self.buffer);
        self.buffer = copy;
        self.cursor = @intCast(@min(update.cursor, self.buffer.len));
        self.keymap = update.keymap;
        self.truncated = update.truncated;
        self.active = true;
        self.generation +%= 1;
    }

    /// Forget the buffer and bump the generation. Used on dismiss and
    /// whenever the popup must go away.
    pub fn clear(self: *State, alloc: Allocator) void {
        alloc.free(self.buffer);
        self.buffer = &.{};
        self.cursor = 0;
        self.truncated = false;
        self.active = false;
        self.generation +%= 1;
    }
};

/// Returns true if `text` may be sent to the shell as a replacement.
/// Rejects anything that could act as input other than plain text: C0
/// controls (so no newline, ESC, BEL, tab), DEL, invalid UTF-8, C1
/// controls, line and paragraph separators, and bidi override/isolate
/// characters that could disguise what gets inserted.
pub fn isSafeAcceptText(text: []const u8) bool {
    if (text.len == 0 or text.len > max_accept_bytes) return false;

    const view = std.unicode.Utf8View.init(text) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| switch (cp) {
        0x00...0x1F,
        0x7F,
        0x80...0x9F,
        0x2028,
        0x2029,
        0x202A...0x202E,
        0x2066...0x2069,
        => return false,
        else => {},
    };
    return true;
}

/// Returns true if `c` must be percent-encoded on the wire, in either
/// direction. Mirrors the shell script's encoder exactly.
pub fn needsPercent(c: u8) bool {
    return switch (c) {
        '%', ';', 0x00...0x1F, 0x7F => true,
        else => false,
    };
}

/// Percent-encode `text` the way the shell does: `%`, `;`, C0 controls
/// and DEL become `%XX` with uppercase hex; everything else is raw.
pub fn percentEncode(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        if (needsPercent(c)) {
            try writer.print("%{X:0>2}", .{c});
        } else {
            try writer.writeByte(c);
        }
    }
}

/// Write the accept sequence for `text`: `CSI 7705 ~`, the
/// percent-encoded text, then BEL. The shell widget bound to
/// `CSI 7705 ~` reads up to the BEL. The caller must have checked the
/// text with `isSafeAcceptText`.
pub fn writeAcceptSequence(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    return writeAcceptSequenceMode(writer, text, .token);
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

/// Like `writeAcceptSequence` with an explicit mode.
pub fn writeAcceptSequenceMode(writer: *std.Io.Writer, text: []const u8, mode: AcceptMode) std.Io.Writer.Error!void {
    std.debug.assert(isSafeAcceptText(text));
    try writer.writeAll(mode.csi());
    try percentEncode(writer, text);
    try writer.writeByte(0x07);
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
};

/// Upper bound on the encoded size of an accept sequence for `len`
/// bytes of text.
pub fn acceptSequenceCapacity(len: usize) usize {
    return "\x1b[7705~".len + len * 3 + 1;
}

test {
    _ = Engine;
    _ = Spec;
    _ = Tokenizer;
    _ = History;
    _ = @import("Fs.zig");
    _ = @import("Generators.zig");
    _ = @import("Rank.zig");
}

test "autocomplete: line accept sequence" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeAcceptSequenceMode(&w, "git push; x", .line);
    try testing.expectEqualStrings("\x1b[7706~git push%3B x\x07", w.buffered());
}

test "autocomplete: keymap names" {
    const testing = std.testing;
    try testing.expectEqual(Keymap.emacs, Keymap.fromName("emacs"));
    try testing.expectEqual(Keymap.viins, Keymap.fromName("viins"));
    try testing.expectEqual(Keymap.vicmd, Keymap.fromName("vicmd"));
    try testing.expectEqual(Keymap.other, Keymap.fromName("visual"));
    try testing.expectEqual(Keymap.other, Keymap.fromName(""));
}

test "autocomplete: state set, clamp, clear, generation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var state: State = .{};
    defer state.deinit(alloc);
    try testing.expectEqual(@as(u64, 0), state.generation);

    const u = try Update.init(alloc, "git sta", 99, "emacs", false);
    defer u.deinit();
    try state.set(alloc, u);
    try testing.expectEqualStrings("git sta", state.buffer);
    try testing.expectEqual(@as(u32, 7), state.cursor);
    try testing.expectEqual(Keymap.emacs, state.keymap);
    try testing.expect(state.active);
    try testing.expectEqual(@as(u64, 1), state.generation);

    const second = try Update.init(alloc, "ls", 1, "vicmd", true);
    defer second.deinit();
    try state.set(alloc, second);
    try testing.expectEqualStrings("ls", state.buffer);
    try testing.expectEqual(@as(u32, 1), state.cursor);
    try testing.expectEqual(@as(u64, 2), state.generation);

    state.clear(alloc);
    try testing.expectEqual(@as(usize, 0), state.buffer.len);
    try testing.expect(!state.active);
    try testing.expectEqual(@as(u64, 3), state.generation);
}

test "autocomplete: rate limit" {
    const testing = std.testing;
    var state: State = .{};

    const t0: std.Io.Timestamp = .{ .nanoseconds = 0 };
    var i: usize = 0;
    while (i < rate_limit_per_second) : (i += 1) {
        try testing.expect(state.admit(t0));
    }
    // The 201st in the same second is dropped, as is one 999ms later.
    try testing.expect(!state.admit(t0));
    try testing.expect(!state.admit(.{ .nanoseconds = 999 * std.time.ns_per_ms }));
    // A new window opens after a second.
    try testing.expect(state.admit(.{ .nanoseconds = 1000 * std.time.ns_per_ms }));
}

test "autocomplete: accept text validation" {
    const testing = std.testing;

    try testing.expect(isSafeAcceptText("status"));
    try testing.expect(isSafeAcceptText("--all"));
    try testing.expect(isSafeAcceptText("my file.txt"));
    try testing.expect(isSafeAcceptText("ünïcödé/路径"));
    try testing.expect(isSafeAcceptText("a;b%c"));

    try testing.expect(!isSafeAcceptText(""));
    try testing.expect(!isSafeAcceptText("ls\n"));
    try testing.expect(!isSafeAcceptText("ls\r"));
    try testing.expect(!isSafeAcceptText("a\tb"));
    try testing.expect(!isSafeAcceptText("\x1b[31m"));
    try testing.expect(!isSafeAcceptText("\x07"));
    try testing.expect(!isSafeAcceptText("del\x7f"));
    try testing.expect(!isSafeAcceptText("\xc2\x85")); // C1 NEL
    try testing.expect(!isSafeAcceptText("\xff")); // invalid UTF-8
    try testing.expect(!isSafeAcceptText("a\u{2028}b"));
    try testing.expect(!isSafeAcceptText("a\u{2029}b"));
    try testing.expect(!isSafeAcceptText("\u{202e}gnp.exe"));
    try testing.expect(!isSafeAcceptText("\u{2066}x\u{2069}"));

    const big = try testing.allocator.alloc(u8, max_accept_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expect(!isSafeAcceptText(big));
    try testing.expect(isSafeAcceptText(big[0..max_accept_bytes]));
}

test "autocomplete: accept sequence encoding" {
    const testing = std.testing;

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeAcceptSequence(&w, "100%; done é");
    try testing.expectEqualStrings("\x1b[7705~100%25%3B done é\x07", w.buffered());

    try testing.expect(acceptSequenceCapacity(12) >= w.buffered().len);
}

test "autocomplete: percent encode covers every byte the shell encodes" {
    const testing = std.testing;

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try percentEncode(&w, "\x00\x1f\x7f%;a");
    try testing.expectEqualStrings("%00%1F%7F%25%3Ba", w.buffered());
}
