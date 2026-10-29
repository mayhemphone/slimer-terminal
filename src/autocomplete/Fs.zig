//! Directory listings for path completion, cached for one second.
//!
//! A listing reads at most `max_entries` names. Symlinks are resolved
//! with one stat each so links to directories complete with a slash.
//! Nothing here ever writes to disk.
const Fs = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_entries = 2000;
pub const ttl_ns: i96 = std.time.ns_per_s;
const slots = 8;

pub const Entry = struct {
    name: []const u8,
    is_dir: bool,
};

pub const Listing = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    entries: []const Entry,
    fetched: Io.Timestamp,
    last_used: u64,
};

alloc: Allocator,
io: Io,
cache: [slots]?*Listing = @splat(null),
tick: u64 = 0,

pub fn init(alloc: Allocator, io: Io) Fs {
    return .{ .alloc = alloc, .io = io };
}

pub fn deinit(self: *Fs) void {
    for (&self.cache) |*slot| if (slot.*) |l| {
        l.arena.deinit();
        self.alloc.destroy(l);
        slot.* = null;
    };
}

/// List an absolute directory, from cache when fresh. Returns null if
/// the directory can't be opened. The result is valid until the next
/// call.
pub fn list(self: *Fs, abs_dir: []const u8, now: Io.Timestamp) ?*const Listing {
    self.tick += 1;
    for (&self.cache) |*slot| if (slot.*) |l| if (std.mem.eql(u8, l.path, abs_dir)) {
        if (l.fetched.durationTo(now).nanoseconds < ttl_ns) {
            l.last_used = self.tick;
            return l;
        }
        l.arena.deinit();
        self.alloc.destroy(l);
        slot.* = null;
    };

    const l = self.read(abs_dir, now) orelse return null;
    var victim: usize = 0;
    var oldest: u64 = std.math.maxInt(u64);
    for (self.cache, 0..) |slot, i| {
        const used = if (slot) |s| s.last_used else 0;
        if (used < oldest) {
            oldest = used;
            victim = i;
        }
        if (slot == null) break;
    }
    if (self.cache[victim]) |old| {
        old.arena.deinit();
        self.alloc.destroy(old);
    }
    self.cache[victim] = l;
    return l;
}

fn read(self: *Fs, abs_dir: []const u8, now: Io.Timestamp) ?*Listing {
    var dir = Io.Dir.cwd().openDir(self.io, abs_dir, .{ .iterate = true }) catch return null;
    defer dir.close(self.io);

    const l = self.alloc.create(Listing) catch return null;
    l.* = .{
        .arena = .init(self.alloc),
        .path = "",
        .entries = &.{},
        .fetched = now,
        .last_used = self.tick,
    };
    const a = l.arena.allocator();
    l.path = a.dupe(u8, abs_dir) catch return fail(self, l);
    var entries: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (entries.items.len < max_entries) {
        const e = (it.next(self.io) catch break) orelse break;
        const is_dir = switch (e.kind) {
            .directory => true,
            .sym_link => link: {
                const st = dir.statFile(self.io, e.name, .{}) catch break :link false;
                break :link st.kind == .directory;
            },
            else => false,
        };
        entries.append(a, .{
            .name = a.dupe(u8, e.name) catch return fail(self, l),
            .is_dir = is_dir,
        }) catch return fail(self, l);
    }
    l.entries = entries.items;
    return l;
}

fn fail(self: *Fs, l: *Listing) ?*Listing {
    l.arena.deinit();
    self.alloc.destroy(l);
    return null;
}

/// Split a partial path into the directory text the user typed (kept in
/// the completion) and the basename prefix to match.
pub const Split = struct {
    /// Everything up to and including the last `/`.
    dir_text: []const u8,
    base: []const u8,
};

pub fn split(partial: []const u8) Split {
    const slash = std.mem.lastIndexOfScalar(u8, partial, '/') orelse
        return .{ .dir_text = "", .base = partial };
    return .{ .dir_text = partial[0 .. slash + 1], .base = partial[slash + 1 ..] };
}

/// Resolve the directory text of a partial path to an absolute path in
/// `buf`: `~` and `~/` use `home`, relative paths join `cwd`. Returns
/// null when it can't be resolved (no cwd, `~user`, too long).
pub fn resolveDir(buf: []u8, cwd: []const u8, home: []const u8, dir_text: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (std.mem.startsWith(u8, dir_text, "/")) {
        w.writeAll(dir_text) catch return null;
    } else if (std.mem.eql(u8, dir_text, "~") or std.mem.startsWith(u8, dir_text, "~/")) {
        if (home.len == 0) return null;
        w.writeAll(home) catch return null;
        w.writeAll(dir_text[1..]) catch return null;
    } else if (std.mem.startsWith(u8, dir_text, "~")) {
        return null;
    } else {
        if (cwd.len == 0 or cwd[0] != '/') return null;
        w.writeAll(cwd) catch return null;
        if (dir_text.len > 0) {
            if (cwd[cwd.len - 1] != '/') w.writeByte('/') catch return null;
            w.writeAll(dir_text) catch return null;
        }
    }
    const out = w.buffered();
    if (out.len == 0) return null;
    return out;
}

test "autocomplete fs: split and resolve" {
    const testing = std.testing;
    const s = split("src/auto");
    try testing.expectEqualStrings("src/", s.dir_text);
    try testing.expectEqualStrings("auto", s.base);
    const s2 = split("README");
    try testing.expectEqualStrings("", s2.dir_text);
    try testing.expectEqualStrings("README", s2.base);

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/w/src/", resolveDir(&buf, "/w", "/h", "src/").?);
    try testing.expectEqualStrings("/w", resolveDir(&buf, "/w", "/h", "").?);
    try testing.expectEqualStrings("/w/../", resolveDir(&buf, "/w/", "/h", "../").?);
    try testing.expectEqualStrings("/etc/", resolveDir(&buf, "/w", "/h", "/etc/").?);
    try testing.expectEqualStrings("/h/", resolveDir(&buf, "/w", "/h", "~/").?);
    try testing.expect(resolveDir(&buf, "/w", "/h", "~bob/") == null);
    try testing.expect(resolveDir(&buf, "", "/h", "src/") == null);
}

test "autocomplete fs: listing and cache" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file.txt", .data = "" });
    try tmp.dir.symLink(testing.io, "sub", "link", .{ .is_directory = true });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &path_buf);

    var fs: Fs = .init(testing.allocator, testing.io);
    defer fs.deinit();
    const t0: Io.Timestamp = .{ .nanoseconds = 0 };
    const l = fs.list(path_buf[0..n], t0).?;
    try testing.expectEqual(@as(usize, 3), l.entries.len);
    for (l.entries) |e| {
        if (std.mem.eql(u8, e.name, "file.txt")) try testing.expect(!e.is_dir);
        if (std.mem.eql(u8, e.name, "sub")) try testing.expect(e.is_dir);
        if (std.mem.eql(u8, e.name, "link")) try testing.expect(e.is_dir);
    }

    // Within the TTL the cached listing is returned even after a change.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new", .data = "" });
    try testing.expectEqual(@as(usize, 3), fs.list(path_buf[0..n], .{ .nanoseconds = 500 * std.time.ns_per_ms }).?.entries.len);
    try testing.expectEqual(@as(usize, 4), fs.list(path_buf[0..n], .{ .nanoseconds = 2 * std.time.ns_per_s }).?.entries.len);

    try testing.expect(fs.list("/definitely/not/here", t0) == null);
}
