//! Shell-like tokenizer for the command line up to the cursor.
//!
//! This is not a zsh parser. It understands enough of the grammar to find
//! the words of the command the cursor is in and the partial token under
//! the cursor: whitespace, single and double quotes, backslash escapes,
//! the separators `;`, `&`, `&&`, `||`, `|`, `|&` and newline (each starts
//! a new command), redirections (the next word is a filename), and
//! subshell parentheses. Command substitution (`$(...)`, backticks) and
//! process substitution (`<(...)`) are kept as opaque word text; if the
//! cursor is inside one that is not closed yet, the result is `opaque`
//! and the engine suggests nothing.
//!
//! The 6A state reports the cursor as a CHARACTER index (zle `$CURSOR`).
//! We count UTF-8 code points to convert it; an invalid byte counts as
//! one character, which matches zsh's behavior for unmetafied bytes
//! closely enough for positioning.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Word = struct {
    /// The unquoted value of the word. Points into memory owned by the
    /// allocator passed to `tokenize`.
    value: []const u8,

    /// Byte range of the word in the buffer, including any quotes.
    start: usize,
    end: usize,
};

pub const Result = struct {
    /// Completed words of the command the cursor is in, before the
    /// current token. Redirection targets are not included.
    words: []const Word,

    /// The partial token that ends at the cursor. Empty (start == end ==
    /// cursor) when the cursor follows whitespace or an operator.
    current: Word,

    /// The cursor as a byte offset into the buffer.
    cursor_byte: usize,

    /// True if no command separator came before the current command, so
    /// the current command starts at the beginning of the buffer.
    first_command: bool,

    /// True if the cursor is in a context we never complete, such as an
    /// unterminated command substitution.
    @"opaque": bool,

    /// True if the current token is a redirection target (a filename).
    redirect: bool,

    /// The quote character open at the cursor, or 0.
    open_quote: u8,
};

/// Convert a character index (code points) into a byte offset, clamped
/// to the buffer.
pub fn byteOffset(buffer: []const u8, chars: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < buffer.len and n < chars) : (n += 1) {
        i += seqLen(buffer, i);
    }
    return @min(i, buffer.len);
}

/// Count characters (code points) in `bytes`. Invalid bytes count as one.
pub fn charCount(bytes: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < bytes.len) : (n += 1) i += seqLen(bytes, i);
    return n;
}

fn seqLen(buffer: []const u8, i: usize) usize {
    const len = std.unicode.utf8ByteSequenceLength(buffer[i]) catch return 1;
    if (i + len > buffer.len) return 1;
    _ = std.unicode.utf8Decode(buffer[i..][0..len]) catch return 1;
    return len;
}

const State = struct {
    alloc: Allocator,
    buf: []const u8,
    end: usize,

    words: std.ArrayList(Word) = .empty,
    cur: std.ArrayList(u8) = .empty,
    in_word: bool = false,
    word_start: usize = 0,
    cur_is_redirect: bool = false,
    redirect_pending: bool = false,
    first_command: bool = true,
    @"opaque": bool = false,
    open_quote: u8 = 0,

    fn startWord(self: *State, i: usize) void {
        if (self.in_word) return;
        self.in_word = true;
        self.word_start = i;
        self.cur.clearRetainingCapacity();
        self.cur_is_redirect = self.redirect_pending;
        self.redirect_pending = false;
    }

    fn finishWord(self: *State, i: usize) Allocator.Error!void {
        if (!self.in_word) return;
        self.in_word = false;
        if (self.cur_is_redirect) {
            self.cur_is_redirect = false;
            return;
        }
        try self.words.append(self.alloc, .{
            .value = try self.alloc.dupe(u8, self.cur.items),
            .start = self.word_start,
            .end = i,
        });
    }

    fn resetCommand(self: *State) void {
        self.in_word = false;
        self.cur_is_redirect = false;
        self.redirect_pending = false;
        self.words.clearRetainingCapacity();
        self.first_command = false;
    }

    /// Skip a `$(...)`, `<(...)` or `>(...)` whose `(` is at `open`,
    /// appending the raw text. Returns the index after the closing paren,
    /// or sets `opaque` if the cursor comes first.
    fn skipParens(self: *State, open: usize) Allocator.Error!usize {
        var depth: usize = 0;
        var i = open;
        var quote: u8 = 0;
        while (i < self.end) : (i += 1) {
            const c = self.buf[i];
            try self.cur.append(self.alloc, c);
            if (quote != 0) {
                if (c == '\\' and quote == '"' and i + 1 < self.end) {
                    i += 1;
                    try self.cur.append(self.alloc, self.buf[i]);
                } else if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '\\' => if (i + 1 < self.end) {
                    i += 1;
                    try self.cur.append(self.alloc, self.buf[i]);
                },
                '\'', '"' => quote = c,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return i + 1;
                },
                else => {},
            }
        }
        self.@"opaque" = true;
        return self.end;
    }

    /// Skip a backtick substitution whose opening backtick is at `open`.
    fn skipBacktick(self: *State, open: usize) Allocator.Error!usize {
        try self.cur.append(self.alloc, '`');
        var i = open + 1;
        while (i < self.end) : (i += 1) {
            const c = self.buf[i];
            try self.cur.append(self.alloc, c);
            if (c == '\\' and i + 1 < self.end) {
                i += 1;
                try self.cur.append(self.alloc, self.buf[i]);
            } else if (c == '`') return i + 1;
        }
        self.@"opaque" = true;
        return self.end;
    }

    /// Skip `${...}` starting at the `$`. Unterminated is opaque.
    fn skipBrace(self: *State, dollar: usize) Allocator.Error!usize {
        var i = dollar;
        while (i < self.end) : (i += 1) {
            try self.cur.append(self.alloc, self.buf[i]);
            if (self.buf[i] == '}') return i + 1;
        }
        self.@"opaque" = true;
        return self.end;
    }
};

/// Tokenize `buffer` up to the character index `cursor_chars`. All
/// returned memory comes from `alloc`; use an arena.
pub fn tokenize(
    alloc: Allocator,
    buffer: []const u8,
    cursor_chars: usize,
) Allocator.Error!Result {
    const end = byteOffset(buffer, cursor_chars);
    var s: State = .{ .alloc = alloc, .buf = buffer, .end = end };

    var i: usize = 0;
    while (i < end and !s.@"opaque") {
        const c = buffer[i];
        switch (c) {
            ' ', '\t' => {
                try s.finishWord(i);
                i += 1;
            },
            '\n', ';' => {
                try s.finishWord(i);
                s.resetCommand();
                i += 1;
            },
            '&' => {
                // `&>` and `&>>` redirect both streams.
                if (i + 1 < end and buffer[i + 1] == '>') {
                    try s.finishWord(i);
                    i += 2;
                    if (i < end and buffer[i] == '>') i += 1;
                    s.redirect_pending = true;
                    continue;
                }
                try s.finishWord(i);
                i += 1;
                if (i < end and buffer[i] == '&') i += 1;
                s.resetCommand();
            },
            '|' => {
                try s.finishWord(i);
                i += 1;
                if (i < end and (buffer[i] == '|' or buffer[i] == '&')) i += 1;
                s.resetCommand();
            },
            '(', ')' => {
                if (s.in_word) {
                    // Glob qualifiers and the like: keep as word text.
                    try s.cur.append(alloc, c);
                    i += 1;
                    continue;
                }
                s.resetCommand();
                i += 1;
            },
            '<', '>' => {
                // `<(` and `>(` are process substitutions: opaque words.
                if (i + 1 < end and buffer[i + 1] == '(') {
                    s.startWord(i);
                    try s.cur.append(alloc, c);
                    i = try s.skipParens(i + 1);
                    continue;
                }
                // A word made only of digits right before the operator
                // is a file descriptor (`2>`), not an argument.
                if (s.in_word and s.cur.items.len > 0 and allDigits(s.cur.items) and
                    s.word_start + s.cur.items.len == i)
                {
                    s.in_word = false;
                } else {
                    try s.finishWord(i);
                }
                i += 1;
                while (i < end and (buffer[i] == '>' or buffer[i] == '<' or
                    buffer[i] == '&' or buffer[i] == '|' or buffer[i] == '!')) i += 1;
                s.redirect_pending = true;
            },
            '\\' => {
                s.startWord(i);
                if (i + 1 < end) {
                    // Backslash-newline is a line continuation.
                    if (buffer[i + 1] != '\n') try s.cur.append(alloc, buffer[i + 1]);
                    i += 2;
                } else {
                    i += 1;
                }
            },
            '\'' => {
                s.startWord(i);
                i += 1;
                if (std.mem.indexOfScalarPos(u8, buffer[0..end], i, '\'')) |cl| {
                    try s.cur.appendSlice(alloc, buffer[i..cl]);
                    i = cl + 1;
                } else {
                    try s.cur.appendSlice(alloc, buffer[i..end]);
                    s.open_quote = '\'';
                    i = end;
                }
            },
            '"' => {
                s.startWord(i);
                i += 1;
                var closed = false;
                while (i < end and !s.@"opaque") {
                    const d = buffer[i];
                    if (d == '"') {
                        closed = true;
                        i += 1;
                        break;
                    }
                    if (d == '\\' and i + 1 < end) {
                        const e = buffer[i + 1];
                        switch (e) {
                            '$', '`', '"', '\\' => try s.cur.append(alloc, e),
                            '\n' => {},
                            else => try s.cur.appendSlice(alloc, buffer[i .. i + 2]),
                        }
                        i += 2;
                        continue;
                    }
                    if (d == '$' and i + 1 < end and buffer[i + 1] == '(') {
                        try s.cur.append(alloc, '$');
                        i = try s.skipParens(i + 1);
                        continue;
                    }
                    if (d == '`') {
                        i = try s.skipBacktick(i);
                        continue;
                    }
                    try s.cur.append(alloc, d);
                    i += 1;
                }
                if (!closed and !s.@"opaque") s.open_quote = '"';
            },
            '`' => {
                s.startWord(i);
                i = try s.skipBacktick(i);
            },
            '$' => {
                s.startWord(i);
                if (i + 1 < end and buffer[i + 1] == '(') {
                    try s.cur.append(alloc, '$');
                    i = try s.skipParens(i + 1);
                } else if (i + 1 < end and buffer[i + 1] == '{') {
                    i = try s.skipBrace(i);
                } else {
                    try s.cur.append(alloc, '$');
                    i += 1;
                }
            },
            else => {
                s.startWord(i);
                try s.cur.append(alloc, c);
                i += 1;
            },
        }
    }

    var current: Word = .{ .value = "", .start = end, .end = end };
    var redirect = s.redirect_pending;
    if (s.in_word) {
        current = .{
            .value = try alloc.dupe(u8, s.cur.items),
            .start = s.word_start,
            .end = end,
        };
        redirect = s.cur_is_redirect;
    }

    return .{
        .words = s.words.items,
        .current = current,
        .cursor_byte = end,
        .first_command = s.first_command,
        .@"opaque" = s.@"opaque",
        .redirect = redirect,
        .open_quote = s.open_quote,
    };
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn expectWords(r: Result, expected: []const []const u8) !void {
    const testing = std.testing;
    try testing.expectEqual(expected.len, r.words.len);
    for (expected, r.words) |e, w| try testing.expectEqualStrings(e, w.value);
}

test "autocomplete tokenizer: plain words and current token" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try tokenize(a, "git commit -m", 13);
    try expectWords(r, &.{ "git", "commit" });
    try testing.expectEqualStrings("-m", r.current.value);
    try testing.expectEqual(@as(usize, 11), r.current.start);
    try testing.expect(r.first_command);

    const r2 = try tokenize(a, "git status ", 11);
    try expectWords(r2, &.{ "git", "status" });
    try testing.expectEqualStrings("", r2.current.value);
    try testing.expectEqual(@as(usize, 11), r2.current.start);

    // Cursor in the middle: only text before it counts.
    const r3 = try tokenize(a, "git checkout main", 6);
    try expectWords(r3, &.{"git"});
    try testing.expectEqualStrings("ch", r3.current.value);
}

test "autocomplete tokenizer: quotes and escapes" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const line = "cd 'my dir'/sub\\ dir \"a\\\"b\" x";
    const r = try tokenize(a, line, line.len);
    try expectWords(r, &.{ "cd", "my dir/sub dir", "a\"b" });
    try testing.expectEqualStrings("x", r.current.value);

    // An open quote at the cursor keeps the token going.
    const r2 = try tokenize(a, "ls \"My Doc", 10);
    try expectWords(r2, &.{"ls"});
    try testing.expectEqualStrings("My Doc", r2.current.value);
    try testing.expectEqual(@as(u8, '"'), r2.open_quote);
    try testing.expectEqual(@as(usize, 3), r2.current.start);

    const r3 = try tokenize(a, "echo 'it''s'", 12);
    try testing.expectEqualStrings("its", r3.current.value);

    // A trailing backslash at the cursor contributes nothing yet.
    const r4 = try tokenize(a, "ls a\\", 5);
    try testing.expectEqualStrings("a", r4.current.value);
}

test "autocomplete tokenizer: separators reset the command" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    inline for (.{ "ls; git st", "ls && git st", "ls || git st", "ls | git st", "ls |& git st", "ls & git st", "(git st", "ls\ngit st" }) |line| {
        const r = try tokenize(a, line, line.len);
        try expectWords(r, &.{"git"});
        try testing.expectEqualStrings("st", r.current.value);
        try testing.expect(!r.first_command);
    }

    // Empty token right after an operator is a new command position.
    const r = try tokenize(a, "make && ", 8);
    try testing.expectEqual(@as(usize, 0), r.words.len);
    try testing.expectEqualStrings("", r.current.value);

    // Quoted separators are just text.
    const q = try tokenize(a, "echo 'a;b' \"c|d\" e", 18);
    try expectWords(q, &.{ "echo", "a;b", "c|d" });
    try testing.expect(q.first_command);
}

test "autocomplete tokenizer: substitutions are opaque" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const closed = try tokenize(a, "echo $(git rev-parse HEAD) fo", 29);
    try testing.expect(!closed.@"opaque");
    try expectWords(closed, &.{ "echo", "$(git rev-parse HEAD)" });
    try testing.expectEqualStrings("fo", closed.current.value);

    const open = try tokenize(a, "echo $(git sta", 14);
    try testing.expect(open.@"opaque");

    const tick = try tokenize(a, "echo `git sta", 13);
    try testing.expect(tick.@"opaque");

    const quoted = try tokenize(a, "echo \"$(ls", 10);
    try testing.expect(quoted.@"opaque");

    const procsub = try tokenize(a, "diff <(ls) <(ls -", 17);
    try testing.expect(procsub.@"opaque");
}

test "autocomplete tokenizer: redirections" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const r = try tokenize(a, "make 2>err.log > out", 20);
    try expectWords(r, &.{"make"});
    try testing.expect(r.redirect);
    try testing.expectEqualStrings("out", r.current.value);

    const r2 = try tokenize(a, "cat < ", 6);
    try testing.expect(r2.redirect);
    try testing.expectEqualStrings("", r2.current.value);

    const r3 = try tokenize(a, "make >log tes", 13);
    try expectWords(r3, &.{"make"});
    try testing.expect(!r3.redirect);
}

test "autocomplete tokenizer: unicode cursor is a character index" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // "cd é/ü" is 6 characters but 8 bytes.
    const line = "cd é/ü";
    try testing.expectEqual(@as(usize, 6), charCount(line));
    const r = try tokenize(a, line, 6);
    try testing.expectEqualStrings("é/ü", r.current.value);
    try testing.expectEqual(@as(usize, 3), r.current.start);
    try testing.expectEqual(line.len, r.cursor_byte);

    // Cursor after "cd é" (4 chars) stops before the slash.
    const r2 = try tokenize(a, line, 4);
    try testing.expectEqualStrings("é", r2.current.value);

    // Out-of-range cursors clamp; invalid bytes count as one char.
    try testing.expectEqual(@as(usize, 3), byteOffset("a\xffb", 99));
    try testing.expectEqual(@as(usize, 2), byteOffset("a\xffb", 2));
}
