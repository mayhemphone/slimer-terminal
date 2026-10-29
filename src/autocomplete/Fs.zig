//! Filesystem access for autocomplete: directory listings (cached for one
//! second), safe small-file reads, and a "is this a local filesystem"
//! check. Everything here runs on the autocomplete worker thread, never
//! on the main thread, and never writes to disk.
//!
//! Safety rules:
//! - Files are opened `O_NONBLOCK` and must be regular files (`fstat`),
//!   so a FIFO or device named `package.json` can't block or be read.
//! - Listings and generators skip non-local and automounted filesystems
//!   (`statfs` without `MNT_LOCAL` or with `MNT_AUTOMOUNTED` on macOS, and
//!   anything under `/net`, `/Network` or `/Volumes` that isn't local),
//!   where a single `stat` can hang.
//! - Listings don't `stat` symlinks; the engine resolves only the few it
//!   is about to show.
const Fs = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const max_entries = 2000;
pub const ttl_ns: i96 = std.time.ns_per_s;
const slots = 8;

pub const Kind = enum { file, dir, link };

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
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
/// the directory can't be opened or is not on a local filesystem. The
/// result is valid until the next call.
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

    if (!isLocal(abs_dir)) return null;
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
        const kind: Kind = switch (e.kind) {
            .directory => .dir,
            .sym_link => .link,
            else => .file,
        };
        entries.append(a, .{
            .name = a.dupe(u8, e.name) catch return fail(self, l),
            .kind = kind,
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

/// Whether `path` (absolute) points at a directory, following links.
/// Used only for the handful of symlinks the engine is about to show.
pub fn isDir(io: Io, path: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
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

// ------------------------------------------------------------ local check

/// Prefixes where network and removable volumes are mounted on macOS.
const remote_prefixes = [_][]const u8{ "/net", "/Network", "/Volumes" };

/// True if `path` is on a local, non-automounted filesystem. Paths under
/// `/net`, `/Network` and `/Volumes` must prove they are local.
/// Unknown (statfs failed) counts as not local for those prefixes and as
/// local elsewhere (the path probably doesn't exist; opening it fails fast).
pub fn isLocal(path: []const u8) bool {
    var under_remote = false;
    for (remote_prefixes) |p| {
        if (std.mem.eql(u8, path, p) or
            (std.mem.startsWith(u8, path, p) and path.len > p.len and path[p.len] == '/'))
            under_remote = true;
    }
    return switch (mountKind(path)) {
        .local => true,
        .remote => false,
        .unknown => !under_remote,
    };
}

const MountKind = enum { local, remote, unknown };

fn mountKind(path: []const u8) MountKind {
    if (comptime !builtin.os.tag.isDarwin()) return .unknown;
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return .unknown;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: darwin.Statfs = undefined;
    if (darwin.statfs(&buf, &st) != 0) return .unknown;
    if (st.f_flags & darwin.MNT_LOCAL == 0) return .remote;
    if (st.f_flags & darwin.MNT_AUTOMOUNTED != 0) return .remote;
    return .local;
}

const darwin = struct {
    const MNT_LOCAL: u32 = 0x00001000;
    const MNT_AUTOMOUNTED: u32 = 0x00400000;

    /// `struct statfs` with 64-bit inodes (the only layout on arm64, and
    /// `statfs$INODE64` on x86_64).
    const Statfs = extern struct {
        f_bsize: u32,
        f_iosize: i32,
        f_blocks: u64,
        f_bfree: u64,
        f_bavail: u64,
        f_files: u64,
        f_ffree: u64,
        f_fsid: [2]i32,
        f_owner: u32,
        f_type: u32,
        f_flags: u32,
        f_fssubtype: u32,
        f_fstypename: [16]u8,
        f_mntonname: [1024]u8,
        f_mntfromname: [1024]u8,
        f_flags_ext: u32,
        f_reserved: [7]u32,
    };

    const statfs = @extern(*const fn ([*:0]const u8, *Statfs) callconv(.c) c_int, .{
        .name = if (builtin.cpu.arch == .x86_64) "statfs$INODE64" else "statfs",
    });
};

// ------------------------------------------------------------ file reads

pub const ReadError = error{ NotRegular, TooLarge, OpenFailed, ReadFailed } || Allocator.Error;

pub const FileInfo = struct {
    mtime_ns: i96,
    size: u64,
};

/// Open `path` read-only and non-blocking and require a regular file.
/// Returns the fd and its info. The caller closes the fd.
fn openRegular(path: []const u8) ReadError!struct { fd: std.c.fd_t, info: FileInfo } {
    if (comptime builtin.os.tag == .windows) @compileError("posix only");
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return error.OpenFailed;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = std.c.open(&buf, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return error.OpenFailed;
    errdefer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return error.OpenFailed;
    if (!std.c.S.ISREG(@intCast(st.mode))) return error.NotRegular;
    const mt = st.mtime();
    return .{ .fd = fd, .info = .{
        .mtime_ns = @as(i96, mt.sec) * std.time.ns_per_s + mt.nsec,
        .size = @intCast(@max(0, st.size)),
    } };
}

/// Read a whole regular file of at most `limit` bytes. Larger files are
/// `error.TooLarge`.
pub fn readRegular(alloc: Allocator, path: []const u8, limit: usize) ReadError![]u8 {
    const f = try openRegular(path);
    defer _ = std.c.close(f.fd);
    if (f.info.size > limit) return error.TooLarge;
    return readFd(alloc, f.fd, limit, false);
}

/// Read at most `limit` bytes from the start of a regular file. Never
/// fails for size: a longer file is cut (the caller parses lines and
/// drops a partial last one).
pub fn readRegularPrefix(alloc: Allocator, path: []const u8, limit: usize) ReadError![]u8 {
    const f = try openRegular(path);
    defer _ = std.c.close(f.fd);
    return readFd(alloc, f.fd, limit, true);
}

/// Read the last `limit` bytes of a regular file. When the file is
/// longer, the partial first line is dropped.
pub fn readRegularTail(alloc: Allocator, path: []const u8, limit: usize) ReadError![]u8 {
    const f = try openRegular(path);
    defer _ = std.c.close(f.fd);
    if (f.info.size <= limit) return readFd(alloc, f.fd, limit, true);
    const start: i64 = @intCast(f.info.size - limit);
    if (std.c.lseek(f.fd, start, std.c.SEEK.SET) < 0) return error.ReadFailed;
    const data = try readFd(alloc, f.fd, limit, true);
    const nl = std.mem.indexOfScalar(u8, data, '\n') orelse {
        alloc.free(data);
        return alloc.alloc(u8, 0);
    };
    const rest = data.len - (nl + 1);
    std.mem.copyForwards(u8, data[0..rest], data[nl + 1 ..]);
    return alloc.realloc(data, rest) catch data[0..rest];
}

/// Stat a regular file without reading it (non-blocking open + fstat).
pub fn infoRegular(path: []const u8) ReadError!FileInfo {
    const f = try openRegular(path);
    defer _ = std.c.close(f.fd);
    return f.info;
}

fn readFd(alloc: Allocator, fd: std.c.fd_t, limit: usize, truncate: bool) ReadError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [64 * 1024]u8 = undefined;
    while (out.items.len < limit) {
        const want = @min(chunk.len, limit - out.items.len);
        const n = std.c.read(fd, &chunk, want);
        if (n < 0) {
            // EAGAIN on a regular file shouldn't happen; treat any error as
            // the end of what we can read without blocking.
            if (out.items.len > 0) break;
            return error.ReadFailed;
        }
        if (n == 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(n)]);
    } else if (!truncate) {
        // Exactly at the limit: make sure there is nothing more.
        var one: [1]u8 = undefined;
        if (std.c.read(fd, &one, 1) > 0) return error.TooLarge;
    }
    return out.toOwnedSlice(alloc);
}

/// Append `bytes` to `path` with `O_APPEND`, creating it with mode 0600.
pub fn appendFile(path: []const u8, bytes: []const u8) !void {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const fd = std.c.open(&buf, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0 or !std.c.S.ISREG(@intCast(st.mode))) return error.NotRegular;
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

/// Replace `path` atomically with `bytes` (write `path.tmp`, mode 0600,
/// then rename).
pub fn replaceFile(path: []const u8, bytes: []const u8) !void {
    var tmp: [std.fs.max_path_bytes:0]u8 = undefined;
    const suffix = ".tmp";
    if (path.len + suffix.len >= tmp.len) return error.NameTooLong;
    @memcpy(tmp[0..path.len], path);
    @memcpy(tmp[path.len..][0..suffix.len], suffix);
    tmp[path.len + suffix.len] = 0;
    var dst: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(dst[0..path.len], path);
    dst[path.len] = 0;

    const fd = std.c.open(&tmp, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    var ok = false;
    defer if (!ok) {
        _ = std.c.unlink(&tmp);
    };
    {
        defer _ = std.c.close(fd);
        var rest = bytes;
        while (rest.len > 0) {
            const n = std.c.write(fd, rest.ptr, rest.len);
            if (n <= 0) return error.WriteFailed;
            rest = rest[@intCast(n)..];
        }
    }
    if (std.c.rename(&tmp, &dst) != 0) return error.RenameFailed;
    ok = true;
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

fn tmpPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..n];
}

test "autocomplete fs: listing, lazy symlinks and cache" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "sub");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file.txt", .data = "" });
    try tmp.dir.symLink(testing.io, "sub", "link", .{ .is_directory = true });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpPath(&tmp, &path_buf);

    var fs: Fs = .init(testing.allocator, testing.io);
    defer fs.deinit();
    const t0: Io.Timestamp = .{ .nanoseconds = 0 };
    const l = fs.list(root, t0).?;
    try testing.expectEqual(@as(usize, 3), l.entries.len);
    for (l.entries) |e| {
        if (std.mem.eql(u8, e.name, "file.txt")) try testing.expectEqual(Kind.file, e.kind);
        if (std.mem.eql(u8, e.name, "sub")) try testing.expectEqual(Kind.dir, e.kind);
        // Not stat'ed while listing.
        if (std.mem.eql(u8, e.name, "link")) try testing.expectEqual(Kind.link, e.kind);
    }
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(isDir(testing.io, try std.fmt.bufPrint(&link_buf, "{s}/link", .{root})));
    try testing.expect(!isDir(testing.io, try std.fmt.bufPrint(&link_buf, "{s}/file.txt", .{root})));

    // Within the TTL the cached listing is returned even after a change.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "new", .data = "" });
    try testing.expectEqual(@as(usize, 3), fs.list(root, .{ .nanoseconds = 500 * std.time.ns_per_ms }).?.entries.len);
    try testing.expectEqual(@as(usize, 4), fs.list(root, .{ .nanoseconds = 2 * std.time.ns_per_s }).?.entries.len);

    try testing.expect(fs.list("/definitely/not/here", t0) == null);
}

test "autocomplete fs: local filesystem check" {
    const testing = std.testing;
    try testing.expect(isLocal("/"));
    try testing.expect(isLocal("/usr"));
    // Missing paths under the remote mount points must prove locality.
    try testing.expect(!isLocal("/net/definitely-not-a-host/x"));
    try testing.expect(!isLocal("/Network/Servers/nothing"));
    try testing.expect(!isLocal("/Volumes/definitely-not-mounted-xyz"));
    // ...but a lookalike prefix is not a mount point.
    try testing.expect(isLocal("/networking-not-a-mount"));
}

test "autocomplete fs: regular file reads" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "hello world" });
    try tmp.dir.createDirPath(testing.io, "d");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpPath(&tmp, &path_buf);
    var p: [std.fs.max_path_bytes]u8 = undefined;

    const a = try std.fmt.bufPrint(&p, "{s}/a.txt", .{root});
    const data = try readRegular(alloc, a, 1024);
    defer alloc.free(data);
    try testing.expectEqualStrings("hello world", data);
    try testing.expectError(error.TooLarge, readRegular(alloc, a, 5));
    const pre = try readRegularPrefix(alloc, a, 5);
    defer alloc.free(pre);
    try testing.expectEqualStrings("hello", pre);
    try testing.expectEqual(@as(u64, 11), (try infoRegular(a)).size);

    // Directories and missing files are refused.
    try testing.expectError(error.NotRegular, readRegular(alloc, try std.fmt.bufPrint(&p, "{s}/d", .{root}), 10));
    try testing.expectError(error.OpenFailed, readRegular(alloc, try std.fmt.bufPrint(&p, "{s}/nope", .{root}), 10));

    // A FIFO is refused without blocking.
    const fifo = try std.fmt.bufPrintSentinel(&p, "{s}/fifo", .{root}, 0);
    const mkfifo = @extern(*const fn ([*:0]const u8, std.c.mode_t) callconv(.c) c_int, .{ .name = "mkfifo" });
    if (mkfifo(fifo, 0o600) == 0) {
        try testing.expectError(error.NotRegular, readRegular(alloc, fifo, 10));
    }

    // Append and replace keep 0600.
    const log = try std.fmt.bufPrint(&p, "{s}/log", .{root});
    try appendFile(log, "one\n");
    try appendFile(log, "two\n");
    const both = try readRegular(alloc, log, 100);
    defer alloc.free(both);
    try testing.expectEqualStrings("one\ntwo\n", both);
    try replaceFile(log, "three\n");
    const replaced = try readRegular(alloc, log, 100);
    defer alloc.free(replaced);
    try testing.expectEqualStrings("three\n", replaced);
    const st = try tmp.dir.statFile(testing.io, "log", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}
