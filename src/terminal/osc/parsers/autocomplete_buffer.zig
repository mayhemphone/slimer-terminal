//! OSC 7704: Slimer autocomplete buffer report (slimer addition).
//!
//! The shell integration script reports the live command line each time
//! the zle edit buffer changes so the terminal can drive an autocomplete
//! popup. One report is a list of `key=value` fields separated by
//! semicolons:
//!
//! ```
//! ESC ] 7704 ; v=1 ; c=<cursor> ; k=<keymap> ; t=<0|1> ; b=<payload> BEL
//! ```
//!
//! - `v`: protocol version. Only `1` is accepted.
//! - `c`: cursor position as a decimal character index into the buffer.
//! - `k`: zle keymap name (`emacs`, `viins`, `vicmd`, ...). Letters,
//!   digits, `_` and `-` only, at most `max_keymap_bytes`.
//! - `t`: `1` if the shell truncated the buffer before encoding it.
//! - `b`: the buffer, percent-encoded. The shell encodes `%`, `;`, every
//!   C0 control (0x00-0x1F) and DEL (0x7F) as `%XX` with uppercase hex.
//!   Everything else, including raw UTF-8, passes through. `b` must be
//!   the last field; everything after `b=` is the payload.
//!
//! Every field is required. Duplicate fields, unknown versions, malformed
//! numbers, malformed percent escapes, and oversized payloads discard the
//! whole report. Unknown keys are skipped so a later revision can add
//! fields without breaking older terminals.
//!
//! The parser percent-decodes the payload **in place** inside the parser's
//! capture buffer, so `Command.buffer` holds the decoded bytes. Decoded
//! bytes may be anything, including control characters. They are
//! untrusted data from the shell and must never be interpreted or
//! executed; the terminal only uses them as a match prefix.
//!
//! Caps (security, non-negotiable): the whole body after `7704;` is at
//! most `max_body_bytes`, and the decoded buffer is at most
//! `max_buffer_bytes`. The body cap is above `Parser.MAX_BUF`, so the
//! sequence is captured through the parser's allocating path and the cap
//! is enforced here, the same way OSC 7501 enforces its own limit.

const autocomplete_buffer = @This();

const std = @import("std");
const osc = @import("../../osc.zig");

const assert = @import("../../../quirks.zig").inlineAssert;
const Parser = osc.Parser;
const OSCCommand = osc.Command;

const log = std.log.scoped(.osc_autocomplete_buffer);

/// The longest body, everything after `7704;`, before decoding.
pub const max_body_bytes = 8192;

/// The longest decoded buffer. The shell truncates to this many bytes
/// before encoding, so a longer value is malformed.
pub const max_buffer_bytes = 4096;

/// The longest keymap name.
pub const max_keymap_bytes = 16;

/// The only protocol version this parser accepts.
pub const version = 1;

/// A parsed OSC 7704 report.
///
/// The slices point into the parser's buffer and are only valid until
/// the next call to the parser. Copy anything you want to keep.
pub const Command = struct {
    /// No C ABI representation; libghostty-vt only identifies the command.
    pub const C = void;

    /// Always `autocomplete_buffer.version`.
    version: u8,

    /// Cursor position as a character index. This may exceed the
    /// decoded buffer length when `truncated` is set, so consumers clamp.
    cursor: u32,

    /// The zle keymap name, validated to `[A-Za-z0-9_-]{1,16}`.
    keymap: []const u8,

    /// The shell truncated the buffer before encoding it.
    truncated: bool,

    /// The command line, already percent-decoded. Untrusted data.
    buffer: []const u8,
};

/// Parse OSC 7704. The body is everything after `7704;`.
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*OSCCommand {
    _ = terminator_ch;
    assert(parser.state == .@"7704");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };

    const data = cap.trailing();
    if (data.len > max_body_bytes) {
        log.debug("OSC 7704 sequence too long len={d}", .{data.len});
        parser.state = .invalid;
        return null;
    }

    const cmd = parseBody(data) catch |err| {
        log.debug("invalid OSC 7704 report err={}", .{err});
        parser.state = .invalid;
        return null;
    };

    parser.command = .{ .autocomplete_buffer = cmd };
    return &parser.command;
}

const Error = error{
    MissingField,
    DuplicateField,
    InvalidVersion,
    InvalidNumber,
    InvalidKeymap,
    InvalidTruncated,
    InvalidEncoding,
    TooLong,
};

/// Parse and validate a body. `data` is mutated: the payload is decoded
/// in place.
fn parseBody(data: []u8) Error!Command {
    var ver: ?u8 = null;
    var cursor: ?u32 = null;
    var keymap: ?[]const u8 = null;
    var truncated: ?bool = null;
    var buffer: ?[]u8 = null;

    var rest: []u8 = data;
    while (rest.len > 0) {
        // `b=` consumes everything that remains, so its value may be
        // split on `;` safely only by the encoder, never by us.
        if (std.mem.startsWith(u8, rest, "b=")) {
            if (buffer != null) return error.DuplicateField;
            buffer = try decodeInPlace(rest[2..]);
            break;
        }

        const field_end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
        const field = rest[0..field_end];
        rest = if (field_end < rest.len) rest[field_end + 1 ..] else rest[rest.len..];

        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..eq];
        const value = field[eq + 1 ..];

        if (std.mem.eql(u8, key, "v")) {
            if (ver != null) return error.DuplicateField;
            const v = parseNumber(value) orelse return error.InvalidVersion;
            if (v != version) return error.InvalidVersion;
            ver = version;
        } else if (std.mem.eql(u8, key, "c")) {
            if (cursor != null) return error.DuplicateField;
            cursor = parseNumber(value) orelse return error.InvalidNumber;
        } else if (std.mem.eql(u8, key, "k")) {
            if (keymap != null) return error.DuplicateField;
            if (!isKeymap(value)) return error.InvalidKeymap;
            keymap = value;
        } else if (std.mem.eql(u8, key, "t")) {
            if (truncated != null) return error.DuplicateField;
            truncated = if (std.mem.eql(u8, value, "0"))
                false
            else if (std.mem.eql(u8, value, "1"))
                true
            else
                return error.InvalidTruncated;
        }
        // Unknown keys are skipped for forward compatibility.
    }

    const buf = buffer orelse return error.MissingField;
    if (buf.len > max_buffer_bytes) return error.TooLong;

    return .{
        .version = ver orelse return error.MissingField,
        .cursor = cursor orelse return error.MissingField,
        .keymap = keymap orelse return error.MissingField,
        .truncated = truncated orelse return error.MissingField,
        .buffer = buf,
    };
}

/// Parse a non-empty string of ASCII digits into a u32. Anything else,
/// including `_` separators and overflow, is null. This doesn't use
/// std.fmt because it accepts underscores and signs.
fn parseNumber(value: []const u8) ?u32 {
    if (value.len == 0 or value.len > 10) return null;
    var n: u64 = 0;
    for (value) |c| {
        const digit = std.fmt.charToDigit(c, 10) catch return null;
        n = n * 10 + digit;
    }
    return std.math.cast(u32, n);
}

fn isKeymap(value: []const u8) bool {
    if (value.len == 0 or value.len > max_keymap_bytes) return false;
    for (value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Percent-decode `buf` in place and return the decoded prefix. A `%`
/// must be followed by exactly two hex digits (either case).
pub fn decodeInPlace(buf: []u8) error{InvalidEncoding}![]u8 {
    var r: usize = 0;
    var w: usize = 0;
    while (r < buf.len) : (w += 1) {
        const c = buf[r];
        if (c != '%') {
            buf[w] = c;
            r += 1;
            continue;
        }

        if (r + 3 > buf.len) return error.InvalidEncoding;
        const hi = std.fmt.charToDigit(buf[r + 1], 16) catch return error.InvalidEncoding;
        const lo = std.fmt.charToDigit(buf[r + 2], 16) catch return error.InvalidEncoding;
        buf[w] = (hi << 4) | lo;
        r += 3;
    }
    return buf[0..w];
}

test "OSC 7704: happy path" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7704;v=1;c=7;k=emacs;t=0;b=git sta");
    const cmd = p.end(0x07).?.autocomplete_buffer;
    try testing.expectEqual(@as(u8, 1), cmd.version);
    try testing.expectEqual(@as(u32, 7), cmd.cursor);
    try testing.expectEqualStrings("emacs", cmd.keymap);
    try testing.expect(!cmd.truncated);
    try testing.expectEqualStrings("git sta", cmd.buffer);
}

test "OSC 7704: ST terminator and vicmd keymap" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7704;v=1;c=0;k=vicmd;t=0;b=");
    const cmd = p.end('\x1b').?.autocomplete_buffer;
    try testing.expectEqual(@as(u32, 0), cmd.cursor);
    try testing.expectEqualStrings("vicmd", cmd.keymap);
    try testing.expectEqualStrings("", cmd.buffer);
}

test "OSC 7704: truncated flag" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7704;v=1;c=4096;k=viins;t=1;b=abc");
    const cmd = p.end(0x07).?.autocomplete_buffer;
    try testing.expect(cmd.truncated);
    try testing.expectEqual(@as(u32, 4096), cmd.cursor);
    try testing.expectEqualStrings("abc", cmd.buffer);
}

test "OSC 7704: encoded ; and % round trip" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // `echo 100%; ls` with the control bytes BEL and ESC embedded.
    p.nextSlice("7704;v=1;c=3;k=emacs;t=0;b=echo%20100%25%3B%20ls%07%1Bé");
    const cmd = p.end(0x07).?.autocomplete_buffer;
    try testing.expectEqualStrings("echo 100%; ls\x07\x1bé", cmd.buffer);
}

test "OSC 7704: lowercase hex and a raw semicolon in the payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // A compliant shell never sends a raw `;` inside `b=`, but since `b`
    // consumes the rest of the body, one is kept as data, not a field.
    p.nextSlice("7704;v=1;c=1;k=emacs;t=0;b=a%3bb;c=9");
    const cmd = p.end(0x07).?.autocomplete_buffer;
    try testing.expectEqualStrings("a;b;c=9", cmd.buffer);
    try testing.expectEqual(@as(u32, 1), cmd.cursor);
}

test "OSC 7704: missing fields" {
    const testing = std.testing;

    const bodies = [_][]const u8{
        "7704;c=1;k=emacs;t=0;b=x", // no v
        "7704;v=1;k=emacs;t=0;b=x", // no c
        "7704;v=1;c=1;t=0;b=x", // no k
        "7704;v=1;c=1;k=emacs;b=x", // no t
        "7704;v=1;c=1;k=emacs;t=0", // no b
        "7704;", // nothing
    };
    for (bodies) |body| {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.nextSlice(body);
        try testing.expect(p.end(0x07) == null);
    }
}

test "OSC 7704: bad version" {
    const testing = std.testing;

    const bodies = [_][]const u8{
        "7704;v=2;c=1;k=emacs;t=0;b=x",
        "7704;v=0;c=1;k=emacs;t=0;b=x",
        "7704;v=;c=1;k=emacs;t=0;b=x",
        "7704;v=one;c=1;k=emacs;t=0;b=x",
    };
    for (bodies) |body| {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.nextSlice(body);
        try testing.expect(p.end(0x07) == null);
    }
}

test "OSC 7704: malformed numbers, keymaps, flags, escapes, duplicates" {
    const testing = std.testing;

    const bodies = [_][]const u8{
        "7704;v=1;c=-1;k=emacs;t=0;b=x",
        "7704;v=1;c=1_0;k=emacs;t=0;b=x",
        "7704;v=1;c=99999999999;k=emacs;t=0;b=x",
        "7704;v=1;c=1;k=;t=0;b=x",
        "7704;v=1;c=1;k=em acs;t=0;b=x",
        "7704;v=1;c=1;k=abcdefghijklmnopq;t=0;b=x",
        "7704;v=1;c=1;k=emacs;t=2;b=x",
        "7704;v=1;c=1;k=emacs;t=;b=x",
        "7704;v=1;c=1;k=emacs;t=0;b=%",
        "7704;v=1;c=1;k=emacs;t=0;b=%4",
        "7704;v=1;c=1;k=emacs;t=0;b=%zz",
        "7704;v=1;c=1;c=2;k=emacs;t=0;b=x",
        "7704;v=1;v=1;c=1;k=emacs;t=0;b=x",
    };
    for (bodies) |body| {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.nextSlice(body);
        try testing.expect(p.end(0x07) == null);
    }
}

test "OSC 7704: unknown keys are skipped" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7704;v=1;x=future;c=2;k=emacs;t=0;b=ok");
    const cmd = p.end(0x07).?.autocomplete_buffer;
    try testing.expectEqualStrings("ok", cmd.buffer);
}

test "OSC 7704: oversized payload" {
    const testing = std.testing;

    // Decoded buffer one byte over the shell cap is rejected.
    {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.nextSlice("7704;v=1;c=0;k=emacs;t=1;b=");
        const big = try testing.allocator.alloc(u8, max_buffer_bytes + 1);
        defer testing.allocator.free(big);
        @memset(big, 'a');
        p.nextSlice(big);
        try testing.expect(p.end(0x07) == null);
    }

    // Exactly at the cap is accepted.
    {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.nextSlice("7704;v=1;c=0;k=emacs;t=1;b=");
        const big = try testing.allocator.alloc(u8, max_buffer_bytes);
        defer testing.allocator.free(big);
        @memset(big, 'a');
        p.nextSlice(big);
        const cmd = p.end(0x07).?.autocomplete_buffer;
        try testing.expectEqual(max_buffer_bytes, cmd.buffer.len);
    }

    // Body over the wire cap is rejected even if it would decode small.
    {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.nextSlice("7704;v=1;c=0;k=emacs;t=1;b=");
        const big = try testing.allocator.alloc(u8, max_body_bytes);
        defer testing.allocator.free(big);
        // "%00" repeated decodes to a third of the size.
        for (big, 0..) |*b, i| b.* = switch (i % 3) {
            0 => '%',
            else => '0',
        };
        p.nextSlice(big);
        try testing.expect(p.end(0x07) == null);
    }
}

test "OSC 7704: larger than the fixed parser buffer still parses" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.nextSlice("7704;v=1;c=0;k=emacs;t=0;b=");
    const big = try testing.allocator.alloc(u8, Parser.MAX_BUF + 100);
    defer testing.allocator.free(big);
    @memset(big, 'z');
    p.nextSlice(big);
    const cmd = p.end(0x07).?.autocomplete_buffer;
    try testing.expectEqual(big.len, cmd.buffer.len);
}

test "OSC 7704: without an allocator, sequences past the fixed buffer are dropped" {
    const testing = std.testing;

    var p: Parser = .init(null);
    defer p.deinit();
    p.nextSlice("7704;v=1;c=0;k=emacs;t=0;b=");
    const big = try testing.allocator.alloc(u8, Parser.MAX_BUF + 100);
    defer testing.allocator.free(big);
    @memset(big, 'z');
    p.nextSlice(big);
    try testing.expect(p.end(0x07) == null);
}

test decodeInPlace {
    const testing = std.testing;

    var buf = "a%25b%3B%3bc%07".*;
    try testing.expectEqualStrings("a%b;;c\x07", try decodeInPlace(&buf));

    var bad = "%G0".*;
    try testing.expectError(error.InvalidEncoding, decodeInPlace(&bad));
}
