//! Command history for autocomplete ranking and whole-line suggestions.
//!
//! Slimer keeps its own append-only `history.log` (mode 0600) in the
//! data directory the apprt hands us. A line is recorded when a command
//! starts (OSC 133 C) from the last command line the shell reported.
//! Lines that start with a space are never recorded, matching zsh's
//! HIST_IGNORE_SPACE convention.
//!
//! On first use we load `history.log` and import the user's zsh history
//! (`$HISTFILE` or `~/.zsh_history`) in memory, once per process. The
//! zsh file is never written. Only zsh entries older than the first
//! Slimer entry are imported so commands are not counted twice.
//!
//! File format, one entry per line, fields separated by `;`:
//!
//!     <unix seconds>;<percent-encoded cwd>;<percent-encoded command>
//!
//! Encoding is the OSC 7704 payload encoding (`%`, `;`, C0 and DEL
//! become `%XX`), so a multi-line command stays on one line. Lines
//! starting with `#` are comments. At most `max_entries` are kept in
//! memory. The file is appended with `O_APPEND` and, when it holds more
//! than `max_entries` lines at load, rewritten to keep the newest ones.
//! All of this runs on the autocomplete worker thread.
const History = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const wire = @import("main.zig");
const Fs = @import("Fs.zig");

const log = std.log.scoped(.autocomplete);

pub const max_entries = 10_000;
/// When the in-memory list reaches this, the oldest entries are dropped
/// back to `max_entries` and the indexes rebuilt.
const compact_at = max_entries + 1_000;
/// The longest line we record or import.
pub const max_line_bytes = 4096;
/// How much of the tail of a history file we read.
const max_read_bytes = 8 * 1024 * 1024;

pub const Entry = struct {
    line: []const u8,
    ts: i64,
    cwd_hash: u64,
};

pub const Stat = struct {
    count: u32 = 0,
    last: i64 = 0,
    /// cwd of the most recent use.
    cwd_hash: u64 = 0,
    /// Uses in any cwd equal to the query's (approximated by the most
    /// recent ones): bumped when the cwd repeats.
    cwd_count: u32 = 0,

    fn bump(self: *Stat, ts: i64, cwd_hash: u64) void {
        self.count +|= 1;
        if (cwd_hash != 0 and cwd_hash == self.cwd_hash) self.cwd_count +|= 1 else self.cwd_count = 1;
        if (ts >= self.last) {
            self.last = ts;
            self.cwd_hash = cwd_hash;
        }
    }
};

alloc: Allocator,
io: Io,

/// `history.log` path, owned. Null disables persistence.
log_path: ?[]const u8 = null,
/// zsh history file to import, owned. Null disables the import.
import_path: ?[]const u8 = null,

loaded: bool = false,

/// Oldest first. Each entry owns its line.
entries: std.ArrayList(Entry) = .empty,

/// Unique lines; keys borrow from `entries`.
lines: std.StringHashMapUnmanaged(Stat) = .empty,

/// Per-command word stats, keyed `<command>\x00<word>`. Keys live in
/// `token_arena`, which is reset when the indexes are rebuilt.
tokens: std.StringHashMapUnmanaged(Stat) = .empty,
token_arena: std.heap.ArenaAllocator,

pub fn init(alloc: Allocator, io: Io) History {
    return .{ .alloc = alloc, .io = io, .token_arena = .init(alloc) };
}

pub fn deinit(self: *History) void {
    for (self.entries.items) |e| self.alloc.free(e.line);
    self.entries.deinit(self.alloc);
    self.lines.deinit(self.alloc);
    self.tokens.deinit(self.alloc);
    self.token_arena.deinit();
    if (self.log_path) |p| self.alloc.free(p);
    if (self.import_path) |p| self.alloc.free(p);
}

/// Set the file paths. Takes effect for loading only if called before
/// first use; the log path is used for every later append.
pub fn setPaths(self: *History, log_path: ?[]const u8, import_path: ?[]const u8) Allocator.Error!void {
    const lp = if (log_path) |p| try self.alloc.dupe(u8, p) else null;
    errdefer if (lp) |p| self.alloc.free(p);
    const ip = if (import_path) |p| try self.alloc.dupe(u8, p) else null;
    if (self.log_path) |p| self.alloc.free(p);
    if (self.import_path) |p| self.alloc.free(p);
    self.log_path = lp;
    self.import_path = ip;
}

pub fn cwdHash(cwd: []const u8) u64 {
    if (cwd.len == 0) return 0;
    return std.hash.Wyhash.hash(0x51173e, cwd);
}

/// Whether a submitted line should be recorded at all.
pub fn shouldRecord(line: []const u8) bool {
    if (line.len == 0 or line.len > max_line_bytes) return false;
    if (line[0] == ' ' or line[0] == '\t') return false;
    if (std.mem.trim(u8, line, " \t\r\n").len == 0) return false;
    if (std.mem.indexOfScalar(u8, line, 0) != null) return false;
    return true;
}

/// Load the log and import zsh history if we haven't yet.
pub fn ensureLoaded(self: *History) void {
    if (self.loaded) return;
    self.loaded = true;

    var log_entries: std.ArrayList(Entry) = .empty;
    defer log_entries.deinit(self.alloc);
    if (self.log_path) |p| {
        if (readTail(self.alloc, self.io, p)) |data| {
            defer self.alloc.free(data);
            parseLog(self.alloc, data, &log_entries) catch {};
            rotate(p, data);
        } else |err| switch (err) {
            error.OpenFailed => {},
            else => log.warn("autocomplete: cannot read history log err={}", .{err}),
        }
    }

    var zsh_entries: std.ArrayList(Entry) = .empty;
    defer zsh_entries.deinit(self.alloc);
    if (self.import_path) |p| {
        if (readTail(self.alloc, self.io, p)) |data| {
            defer self.alloc.free(data);
            parseZsh(self.alloc, data, &zsh_entries) catch {};
        } else |err| switch (err) {
            error.OpenFailed => {},
            else => log.debug("autocomplete: cannot import zsh history err={}", .{err}),
        }
    }

    // Only zsh entries older than our own first entry.
    const cutoff: i64 = if (log_entries.items.len > 0) log_entries.items[0].ts else std.math.maxInt(i64);
    for (zsh_entries.items) |e| {
        if (e.ts < cutoff) {
            self.entries.append(self.alloc, e) catch {
                self.alloc.free(e.line);
                continue;
            };
        } else self.alloc.free(e.line);
    }
    zsh_entries.clearRetainingCapacity();
    for (log_entries.items) |e| self.entries.append(self.alloc, e) catch self.alloc.free(e.line);
    log_entries.clearRetainingCapacity();

    self.trimTo(max_entries);
    self.rebuild();
}

/// Record a submitted command line. Appends to the log file.
pub fn record(self: *History, raw_line: []const u8, cwd: []const u8, now: i64) void {
    const line = std.mem.trimEnd(u8, raw_line, " \t\r\n");
    if (!shouldRecord(line)) return;
    self.ensureLoaded();

    const owned = self.alloc.dupe(u8, line) catch return;
    const h = cwdHash(cwd);
    self.entries.append(self.alloc, .{ .line = owned, .ts = now, .cwd_hash = h }) catch {
        self.alloc.free(owned);
        return;
    };
    if (self.entries.items.len >= compact_at) {
        self.trimTo(max_entries);
        self.rebuild();
    } else {
        self.index(self.entries.items[self.entries.items.len - 1]);
    }

    if (self.log_path) |p| self.append(p, line, cwd, now) catch |err| {
        log.warn("autocomplete: cannot append to history log err={}", .{err});
    };
}

/// Frequency stats for a whole line, if it was used.
pub fn lineStat(self: *const History, line: []const u8) ?Stat {
    return self.lines.get(line);
}

/// Stats for `word` used as an argument of `command`.
pub fn tokenStat(self: *const History, command: []const u8, word: []const u8) ?Stat {
    var buf: [512]u8 = undefined;
    if (command.len + word.len + 1 > buf.len) return null;
    @memcpy(buf[0..command.len], command);
    buf[command.len] = 0;
    @memcpy(buf[command.len + 1 ..][0..word.len], word);
    return self.tokens.get(buf[0 .. command.len + 1 + word.len]);
}

/// Iterate unique lines with their stats.
pub fn lineIterator(self: *const History) std.StringHashMapUnmanaged(Stat).Iterator {
    return self.lines.iterator();
}

fn trimTo(self: *History, n: usize) void {
    if (self.entries.items.len <= n) return;
    const drop = self.entries.items.len - n;
    for (self.entries.items[0..drop]) |e| self.alloc.free(e.line);
    self.entries.replaceRangeAssumeCapacity(0, drop, &.{});
}

fn rebuild(self: *History) void {
    self.lines.clearRetainingCapacity();
    self.tokens.clearRetainingCapacity();
    _ = self.token_arena.reset(.retain_capacity);
    for (self.entries.items) |e| self.index(e);
}

fn index(self: *History, e: Entry) void {
    const gop = self.lines.getOrPut(self.alloc, e.line) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.bump(e.ts, e.cwd_hash);

    // Word stats: split the line into simple commands on the common
    // separators and count each later word against its command word.
    // The command word itself is counted under the empty command.
    var cmd_it = std.mem.tokenizeAny(u8, e.line, ";|&\n");
    while (cmd_it.next()) |cmd_text| {
        var words = std.mem.tokenizeAny(u8, cmd_text, " \t");
        const first = words.next() orelse continue;
        self.bumpToken("", first, e);
        var n: usize = 0;
        while (words.next()) |w| : (n += 1) {
            if (n >= 16) break;
            self.bumpToken(first, w, e);
        }
    }
}

fn bumpToken(self: *History, command: []const u8, word: []const u8, e: Entry) void {
    const key_len = command.len + 1 + word.len;
    if (key_len > 512) return;
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..command.len], command);
    buf[command.len] = 0;
    @memcpy(buf[command.len + 1 ..][0..word.len], word);
    const key = buf[0..key_len];
    const tg = self.tokens.getOrPut(self.alloc, key) catch return;
    if (!tg.found_existing) {
        tg.key_ptr.* = self.token_arena.allocator().dupe(u8, key) catch {
            _ = self.tokens.remove(key);
            return;
        };
        tg.value_ptr.* = .{};
    }
    tg.value_ptr.bump(e.ts, e.cwd_hash);
}

const log_header = "# slimer autocomplete history v1\n";

fn append(self: *History, path: []const u8, line: []const u8, cwd: []const u8, now: i64) !void {
    if (std.fs.path.dirname(path)) |dir| {
        Io.Dir.cwd().createDirPath(self.io, dir) catch {};
    }
    var buf: [3 * (max_line_bytes + 1024) + 128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const exists = if (Fs.infoRegular(path)) |info| info.size > 0 else |_| false;
    if (!exists) try w.writeAll(log_header);
    try w.print("{d};", .{now});
    try wire.percentEncode(&w, cwd[0..@min(cwd.len, 1024)]);
    try w.writeByte(';');
    try wire.percentEncode(&w, line);
    try w.writeByte('\n');
    try Fs.appendFile(path, w.buffered());
}

/// If the log text read at load holds more than `max_entries` entry lines,
/// rewrite the file with only the newest `max_entries`.
fn rotate(path: []const u8, data: []const u8) void {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |l| {
        if (l.len > 0 and l[0] != '#') count += 1;
    }
    if (count <= max_entries) return;
    var skip = count - max_entries;
    var off: usize = 0;
    while (skip > 0 and off < data.len) {
        const nl = std.mem.indexOfScalarPos(u8, data, off, '\n') orelse data.len;
        if (nl > off and data[off] != '#') skip -= 1;
        off = @min(data.len, nl + 1);
    }
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const out = std.mem.concat(a, u8, &.{ log_header, data[off..] }) catch return;
    defer a.free(out);
    Fs.replaceFile(path, out) catch |err| {
        log.warn("autocomplete: cannot rotate history log err={}", .{err});
    };
}

fn readTail(alloc: Allocator, io: Io, path: []const u8) Fs.ReadError![]u8 {
    _ = io;
    return Fs.readRegularTail(alloc, path, max_read_bytes);
}

fn percentDecode(alloc: Allocator, s: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, s.len);
    errdefer alloc.free(out);
    var i: usize = 0;
    var o: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (i + 2 >= s.len) return error.Invalid;
            const v = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.Invalid;
            out[o] = v;
            i += 3;
        } else {
            out[o] = s[i];
            i += 1;
        }
        o += 1;
    }
    return alloc.realloc(out, o) catch out[0..o];
}

/// Parse `history.log` content. Appends owned entries to `out`. Bad
/// lines are skipped.
pub fn parseLog(alloc: Allocator, data: []const u8, out: *std.ArrayList(Entry)) Allocator.Error!void {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        if (raw.len == 0 or raw[0] == '#') continue;
        var f = std.mem.splitScalar(u8, raw, ';');
        const ts_s = f.next() orelse continue;
        const cwd_s = f.next() orelse continue;
        const line_s = f.next() orelse continue;
        if (f.next() != null) continue;
        const ts = std.fmt.parseInt(i64, ts_s, 10) catch continue;
        const cwd = percentDecode(alloc, cwd_s) catch continue;
        defer alloc.free(cwd);
        const line = percentDecode(alloc, line_s) catch continue;
        if (!shouldRecord(line)) {
            alloc.free(line);
            continue;
        }
        out.append(alloc, .{ .line = line, .ts = ts, .cwd_hash = cwdHash(cwd) }) catch |err| {
            alloc.free(line);
            return err;
        };
    }
}

/// zsh's metafication: byte 0x83 means "the next byte XOR 32".
const zsh_meta = 0x83;

/// Parse a zsh history file (plain or EXTENDED_HISTORY). Appends owned
/// entries to `out`; plain entries get timestamp 0. Multi-line commands
/// (lines ending in a backslash) are joined with newlines.
pub fn parseZsh(alloc: Allocator, data: []const u8, out: *std.ArrayList(Entry)) Allocator.Error!void {
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(alloc);
    var cur_ts: i64 = 0;
    var continuing = false;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        var line = raw_line;
        if (!continuing) {
            cur.clearRetainingCapacity();
            cur_ts = 0;
            // `: <start>:<elapsed>;<command>`
            if (std.mem.startsWith(u8, line, ": ")) ext: {
                const semi = std.mem.indexOfScalar(u8, line, ';') orelse break :ext;
                const meta = line[2..semi];
                const colon = std.mem.indexOfScalar(u8, meta, ':') orelse break :ext;
                cur_ts = std.fmt.parseInt(i64, std.mem.trim(u8, meta[0..colon], " "), 10) catch break :ext;
                line = line[semi + 1 ..];
            }
        }

        // Unmetafy into `cur`.
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] == zsh_meta and i + 1 < line.len) {
                i += 1;
                try cur.append(alloc, line[i] ^ 32);
            } else try cur.append(alloc, line[i]);
        }

        // A trailing backslash continues the command on the next line.
        if (cur.items.len > 0 and cur.items[cur.items.len - 1] == '\\' and it.peek() != null) {
            cur.items[cur.items.len - 1] = '\n';
            continuing = true;
            continue;
        }
        continuing = false;

        const cmd = std.mem.trimEnd(u8, cur.items, " \t\r\n");
        if (!shouldRecord(cmd)) continue;
        const owned = try alloc.dupe(u8, cmd);
        out.append(alloc, .{ .line = owned, .ts = cur_ts, .cwd_hash = 0 }) catch |err| {
            alloc.free(owned);
            return err;
        };
    }
}

fn freeEntries(alloc: Allocator, list: *std.ArrayList(Entry)) void {
    for (list.items) |e| alloc.free(e.line);
    list.deinit(alloc);
}

test "autocomplete history: zsh extended and plain formats" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var list: std.ArrayList(Entry) = .empty;
    defer freeEntries(alloc, &list);

    const data = ": 1700000000:0;git status\n" ++
        ": 1700000005:12;echo one\\\ntwo\n" ++
        "plain command\n" ++
        ": 1700000010:0; secret\n" ++
        "ls caf\x83\xc3\xa9\n" ++ // metafied 0xE3 -> 0xC3 ^ 32
        ": bogus;ok\n" ++
        "\n";
    try parseZsh(alloc, data, &list);

    try testing.expectEqual(@as(usize, 5), list.items.len);
    try testing.expectEqualStrings("git status", list.items[0].line);
    try testing.expectEqual(@as(i64, 1700000000), list.items[0].ts);
    try testing.expectEqualStrings("echo one\ntwo", list.items[1].line);
    try testing.expectEqual(@as(i64, 1700000005), list.items[1].ts);
    try testing.expectEqualStrings("plain command", list.items[2].line);
    try testing.expectEqual(@as(i64, 0), list.items[2].ts);
    // The leading-space entry is skipped.
    try testing.expectEqualStrings("ls caf\xe3\xa9", list.items[3].line);
    // An unparseable extended header is kept as a plain line.
    try testing.expectEqualStrings(": bogus;ok", list.items[4].line);
}

test "autocomplete history: log round trip, ignore space, stats" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const log_path = try std.fs.path.join(alloc, &.{ path_buf[0..dir_len], "sub", "history.log" });
    defer alloc.free(log_path);
    const zsh_path = try std.fs.path.join(alloc, &.{ path_buf[0..dir_len], "zsh_history" });
    defer alloc.free(zsh_path);
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "zsh_history",
        .data = ": 100:0;git status\n: 200:0;git commit -m x\n: 999999:0;git push\n",
    });

    {
        var h: History = .init(alloc, testing.io);
        defer h.deinit();
        try h.setPaths(log_path, zsh_path);
        h.record("git push origin main", "/repo", 1000);
        h.record(" secret token", "/repo", 1001);
        h.record("multi;line\nx%y", "/a;b", 1002);
        h.record("git push origin main", "/repo", 1003);

        // Nothing logged yet, so all zsh entries (ts < first log entry
        // at load time, which was empty) are imported.
        try testing.expectEqual(@as(usize, 6), h.entries.items.len);
        const s = h.lineStat("git push origin main").?;
        try testing.expectEqual(@as(u32, 2), s.count);
        try testing.expectEqual(@as(i64, 1003), s.last);
        try testing.expect(h.lineStat(" secret token") == null);
        try testing.expectEqual(@as(u32, 3), h.tokenStat("git", "push").?.count);
        try testing.expectEqual(@as(u32, 2), h.tokenStat("git", "origin").?.count);
        try testing.expectEqual(@as(u32, 5), h.tokenStat("", "git").?.count);
    }

    // The file is 0600 and round-trips.
    const st = try tmp.dir.statFile(testing.io, "sub/history.log", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);

    {
        var h: History = .init(alloc, testing.io);
        defer h.deinit();
        try h.setPaths(log_path, zsh_path);
        h.ensureLoaded();
        // zsh entries older than ts 1000 (two of them) plus three logged.
        try testing.expectEqual(@as(usize, 5), h.entries.items.len);
        try testing.expectEqualStrings("git status", h.entries.items[0].line);
        try testing.expectEqualStrings("multi;line\nx%y", h.entries.items[3].line);
        try testing.expectEqual(History.cwdHash("/a;b"), h.entries.items[3].cwd_hash);
        try testing.expect(h.lineStat("git push") == null);
    }
}

test "autocomplete history: log rotation keeps the newest entries" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    try data.appendSlice(alloc, log_header);
    var i: usize = 0;
    while (i < max_entries + 50) : (i += 1) try data.print(alloc, "{d};%2F;cmd {d}\n", .{ i, i });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "history.log", .data = data.items });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);
    const log_path = try std.fs.path.join(alloc, &.{ path_buf[0..n], "history.log" });
    defer alloc.free(log_path);

    var h: History = .init(alloc, testing.io);
    defer h.deinit();
    try h.setPaths(log_path, null);
    h.ensureLoaded();
    try testing.expectEqual(@as(usize, max_entries), h.entries.items.len);

    const after = try Fs.readRegular(alloc, log_path, 16 * 1024 * 1024);
    defer alloc.free(after);
    try testing.expect(std.mem.startsWith(u8, after, log_header));
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, after, '\n');
    while (it.next()) |l| {
        if (l.len > 0 and l[0] != '#') lines += 1;
    }
    try testing.expectEqual(@as(usize, max_entries), lines);
    try testing.expect(std.mem.indexOf(u8, after, ";cmd 49\n") == null);
    try testing.expect(std.mem.indexOf(u8, after, ";cmd 50\n") != null);
}

test "autocomplete history: cap keeps the newest entries" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var h: History = .init(alloc, testing.io);
    defer h.deinit();
    h.loaded = true;

    var buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < compact_at + 5) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "cmd {d}", .{i});
        h.record(line, "", @intCast(i));
    }
    try testing.expect(h.entries.items.len <= max_entries + 5);
    try testing.expect(h.lineStat("cmd 0") == null);
    try testing.expect(h.lineStat(try std.fmt.bufPrint(&buf, "cmd {d}", .{compact_at + 4})) != null);
    try testing.expectEqual(h.entries.items.len, h.lines.count());
}
