//! Native generators: completions that Fig computes by running a
//! script, reimplemented by reading files directly. Nothing here spawns
//! a process.
//!
//! - git branches, remotes and tags: read `HEAD`, `refs/`, `packed-refs`
//!   and `config` of the repository found by walking up from the cwd.
//!   Worktrees (`.git` file with `gitdir:`) and `commondir` are handled.
//! - package.json scripts: the nearest `package.json` walking up.
//! - make targets: a `^target:` scan of the Makefile in the cwd.
//!
//! Results are cached per (kind, cwd) for one second.
const Generators = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Native = @import("Spec.zig").Native;

pub const ttl_ns: i96 = std.time.ns_per_s;
pub const max_items = 2000;
pub const max_make_targets = 200;
const max_file_bytes = 1024 * 1024;
const max_ref_depth = 8;
const slots = 8;

pub const Item = struct {
    name: []const u8,
    description: []const u8 = "",
    /// Sort hint: higher first (current branch, local before remote).
    boost: f32 = 0,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    kind: Native,
    cwd: []const u8,
    items: []const Item,
    fetched: Io.Timestamp,
    last_used: u64,
};

alloc: Allocator,
io: Io,
cache: [slots]?*Result = @splat(null),
tick: u64 = 0,

pub fn init(alloc: Allocator, io: Io) Generators {
    return .{ .alloc = alloc, .io = io };
}

pub fn deinit(self: *Generators) void {
    for (&self.cache) |*slot| if (slot.*) |r| {
        r.arena.deinit();
        self.alloc.destroy(r);
        slot.* = null;
    };
}

/// Run a native generator for `cwd` (absolute). Returns an empty list
/// when there is nothing to offer. Valid until the next call.
pub fn get(self: *Generators, kind: Native, cwd: []const u8, now: Io.Timestamp) []const Item {
    self.tick += 1;
    for (&self.cache) |*slot| if (slot.*) |r| if (r.kind == kind and std.mem.eql(u8, r.cwd, cwd)) {
        if (r.fetched.durationTo(now).nanoseconds < ttl_ns) {
            r.last_used = self.tick;
            return r.items;
        }
        r.arena.deinit();
        self.alloc.destroy(r);
        slot.* = null;
    };

    const r = self.alloc.create(Result) catch return &.{};
    r.* = .{
        .arena = .init(self.alloc),
        .kind = kind,
        .cwd = "",
        .items = &.{},
        .fetched = now,
        .last_used = self.tick,
    };
    const a = r.arena.allocator();
    r.cwd = a.dupe(u8, cwd) catch "";
    var items: std.ArrayList(Item) = .empty;
    if (cwd.len > 0 and cwd[0] == '/') {
        switch (kind) {
            .git_branches, .git_remotes, .git_tags => gitRefs(a, self.io, cwd, kind, &items) catch {},
            .package_scripts => packageScripts(a, self.io, cwd, &items) catch {},
            .make_targets => makeTargets(a, self.io, cwd, &items) catch {},
        }
    }
    r.items = items.items;

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
    self.cache[victim] = r;
    return r.items;
}

fn readSmall(a: Allocator, io: Io, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_file_bytes));
}

const GitDirs = struct {
    /// Per-worktree git dir (HEAD lives here).
    git_dir: []const u8,
    /// Shared dir (refs, packed-refs, config).
    common_dir: []const u8,
};

/// Walk up from `cwd` to find the repository.
pub fn findGit(a: Allocator, io: Io, cwd: []const u8) !?GitDirs {
    var dir: []const u8 = cwd;
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        const dotgit = try std.fs.path.join(a, &.{ dir, ".git" });
        if (Io.Dir.cwd().statFile(io, dotgit, .{})) |st| {
            const git_dir: []const u8 = switch (st.kind) {
                .directory => dotgit,
                .file => gd: {
                    const text = readSmall(a, io, dotgit) catch return null;
                    const line = std.mem.trim(u8, text, " \t\r\n");
                    if (!std.mem.startsWith(u8, line, "gitdir:")) return null;
                    const target = std.mem.trim(u8, line["gitdir:".len..], " \t");
                    break :gd if (std.fs.path.isAbsolute(target))
                        target
                    else
                        try std.fs.path.resolve(a, &.{ dir, target });
                },
                else => return null,
            };
            var common = git_dir;
            const cd_path = try std.fs.path.join(a, &.{ git_dir, "commondir" });
            if (readSmall(a, io, cd_path)) |text| {
                const t = std.mem.trim(u8, text, " \t\r\n");
                if (t.len > 0) common = if (std.fs.path.isAbsolute(t))
                    t
                else
                    try std.fs.path.resolve(a, &.{ git_dir, t });
            } else |_| {}
            return .{ .git_dir = git_dir, .common_dir = common };
        } else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null;
        dir = parent;
    }
    return null;
}

fn gitRefs(a: Allocator, io: Io, cwd: []const u8, kind: Native, out: *std.ArrayList(Item)) !void {
    const dirs = (try findGit(a, io, cwd)) orelse return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    switch (kind) {
        .git_branches => {
            // Current branch first.
            var current: []const u8 = "";
            const head_path = try std.fs.path.join(a, &.{ dirs.git_dir, "HEAD" });
            if (readSmall(a, io, head_path)) |text| {
                const t = std.mem.trim(u8, text, " \t\r\n");
                if (std.mem.startsWith(u8, t, "ref: refs/heads/")) current = t["ref: refs/heads/".len..];
            } else |_| {}

            try listRefs(a, io, dirs.common_dir, "refs/heads", "", "Branch", 2, out, &seen);
            try listRefs(a, io, dirs.common_dir, "refs/remotes", "", "Remote branch", 0, out, &seen);
            try packedRefs(a, io, dirs.common_dir, out, &seen, .branches);
            for (out.items) |*it| if (std.mem.eql(u8, it.name, current)) {
                it.description = "Current branch";
                it.boost = 3;
            };
        },
        .git_tags => {
            try listRefs(a, io, dirs.common_dir, "refs/tags", "", "Tag", 0, out, &seen);
            try packedRefs(a, io, dirs.common_dir, out, &seen, .tags);
        },
        .git_remotes => {
            const cfg_path = try std.fs.path.join(a, &.{ dirs.common_dir, "config" });
            if (readSmall(a, io, cfg_path)) |text| {
                var lines = std.mem.splitScalar(u8, text, '\n');
                while (lines.next()) |raw| {
                    const l = std.mem.trim(u8, raw, " \t\r");
                    const prefix = "[remote \"";
                    if (!std.mem.startsWith(u8, l, prefix) or !std.mem.endsWith(u8, l, "\"]")) continue;
                    const name = l[prefix.len .. l.len - 2];
                    if (name.len == 0 or seen.contains(name)) continue;
                    try seen.put(a, name, {});
                    try out.append(a, .{ .name = name, .description = "Remote" });
                }
            } else |_| {}
        },
        else => unreachable,
    }
}

/// Recursively list ref names under `<root>/<sub>`, stripping the
/// leading `refs/<kind>/`.
fn listRefs(
    a: Allocator,
    io: Io,
    root: []const u8,
    sub: []const u8,
    prefix: []const u8,
    description: []const u8,
    boost: f32,
    out: *std.ArrayList(Item),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    try listRefsDepth(a, io, root, sub, prefix, description, boost, out, seen, 0);
}

fn listRefsDepth(
    a: Allocator,
    io: Io,
    root: []const u8,
    sub: []const u8,
    prefix: []const u8,
    description: []const u8,
    boost: f32,
    out: *std.ArrayList(Item),
    seen: *std.StringHashMapUnmanaged(void),
    depth: usize,
) !void {
    if (depth > max_ref_depth or out.items.len >= max_items) return;
    const path = try std.fs.path.join(a, &.{ root, sub, prefix });
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (out.items.len >= max_items) return;
        const name = if (prefix.len == 0)
            try a.dupe(u8, e.name)
        else
            try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, e.name });
        switch (e.kind) {
            .directory => try listRefsDepth(a, io, root, sub, name, description, boost, out, seen, depth + 1),
            .file => {
                // `origin/HEAD` is a symbolic ref, not a branch.
                if (std.mem.endsWith(u8, name, "/HEAD") or std.mem.eql(u8, name, "HEAD")) continue;
                if (seen.contains(name)) continue;
                try seen.put(a, name, {});
                try out.append(a, .{ .name = name, .description = description, .boost = boost });
            },
            else => {},
        }
    }
}

const PackedKind = enum { branches, tags };

fn packedRefs(
    a: Allocator,
    io: Io,
    common: []const u8,
    out: *std.ArrayList(Item),
    seen: *std.StringHashMapUnmanaged(void),
    kind: PackedKind,
) !void {
    const path = try std.fs.path.join(a, &.{ common, "packed-refs" });
    const text = readSmall(a, io, path) catch return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (out.items.len >= max_items) return;
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#' or l[0] == '^') continue;
        const sp = std.mem.indexOfScalar(u8, l, ' ') orelse continue;
        const ref = l[sp + 1 ..];
        var name: []const u8 = undefined;
        var desc: []const u8 = undefined;
        var boost: f32 = 0;
        switch (kind) {
            .branches => if (std.mem.startsWith(u8, ref, "refs/heads/")) {
                name = ref["refs/heads/".len..];
                desc = "Branch";
                boost = 2;
            } else if (std.mem.startsWith(u8, ref, "refs/remotes/")) {
                name = ref["refs/remotes/".len..];
                desc = "Remote branch";
                if (std.mem.endsWith(u8, name, "/HEAD")) continue;
            } else continue,
            .tags => if (std.mem.startsWith(u8, ref, "refs/tags/")) {
                name = ref["refs/tags/".len..];
                desc = "Tag";
            } else continue,
        }
        if (name.len == 0 or seen.contains(name)) continue;
        try seen.put(a, name, {});
        try out.append(a, .{ .name = name, .description = desc, .boost = boost });
    }
}

fn packageScripts(a: Allocator, io: Io, cwd: []const u8, out: *std.ArrayList(Item)) !void {
    var dir: []const u8 = cwd;
    var depth: usize = 0;
    const text = while (depth < 64) : (depth += 1) {
        const p = try std.fs.path.join(a, &.{ dir, "package.json" });
        if (readSmall(a, io, p)) |t| break t else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return;
        if (parent.len == dir.len) return;
        dir = parent;
    } else return;

    const v = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return;
    if (v != .object) return;
    const scripts = v.object.get("scripts") orelse return;
    if (scripts != .object) return;
    var it = scripts.object.iterator();
    while (it.next()) |kv| {
        if (out.items.len >= max_items) return;
        const desc = switch (kv.value_ptr.*) {
            .string => |s| s,
            else => "",
        };
        try out.append(a, .{ .name = kv.key_ptr.*, .description = desc });
    }
}

fn makeTargets(a: Allocator, io: Io, cwd: []const u8, out: *std.ArrayList(Item)) !void {
    const text = for ([_][]const u8{ "GNUmakefile", "makefile", "Makefile" }) |name| {
        const p = try std.fs.path.join(a, &.{ cwd, name });
        if (readSmall(a, io, p)) |t| break t else |_| {}
    } else return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (out.items.len >= max_make_targets) return;
        if (l.len == 0) continue;
        if (!(std.ascii.isAlphanumeric(l[0]) or l[0] == '_' or l[0] == '/')) continue;
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        // `VAR := x` and `VAR ::= x` are assignments; `a::b` double-colon
        // rules are rare enough to skip too.
        if (colon + 1 < l.len and (l[colon + 1] == '=' or l[colon + 1] == ':')) continue;
        if (std.mem.indexOfScalar(u8, l[0..colon], '=') != null) continue;
        var names = std.mem.tokenizeAny(u8, l[0..colon], " \t");
        while (names.next()) |n| {
            if (out.items.len >= max_make_targets) return;
            if (n[0] == '.' or std.mem.indexOfAny(u8, n, "%$") != null) continue;
            if (seen.contains(n)) continue;
            try seen.put(a, n, {});
            try out.append(a, .{ .name = n, .description = "Make target" });
        }
    }
}

fn sortedNames(items: []const Item, alloc: Allocator) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, items.len);
    for (items, out) |it, *o| o.* = it.name;
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out;
}

fn expectNames(items: []const Item, expected: []const []const u8) !void {
    const testing = std.testing;
    const got = try sortedNames(items, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

fn tmpPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const n = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..n];
}

test "autocomplete generators: git refs from a fake repo" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "repo/.git/refs/heads/feature");
    try d.createDirPath(io, "repo/.git/refs/remotes/origin");
    try d.createDirPath(io, "repo/.git/refs/tags");
    try d.createDirPath(io, "repo/src/deep");
    try d.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try d.writeFile(io, .{ .sub_path = "repo/.git/refs/heads/main", .data = "abc\n" });
    try d.writeFile(io, .{ .sub_path = "repo/.git/refs/heads/feature/x", .data = "abc\n" });
    try d.writeFile(io, .{ .sub_path = "repo/.git/refs/remotes/origin/HEAD", .data = "ref: refs/remotes/origin/main\n" });
    try d.writeFile(io, .{ .sub_path = "repo/.git/refs/remotes/origin/main", .data = "abc\n" });
    try d.writeFile(io, .{ .sub_path = "repo/.git/refs/tags/v1", .data = "abc\n" });
    try d.writeFile(io, .{
        .sub_path = "repo/.git/packed-refs",
        .data = "# pack-refs with: peeled fully-peeled sorted\n" ++
            "abc refs/heads/old\nabc refs/heads/main\nabc refs/remotes/upstream/dev\n" ++
            "abc refs/tags/v0\n^def\n",
    });
    try d.writeFile(io, .{
        .sub_path = "repo/.git/config",
        .data = "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = x\n[remote \"upstream\"]\n\turl = y\n",
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpPath(&tmp, &buf);
    const cwd = try std.fs.path.join(testing.allocator, &.{ root, "repo/src/deep" });
    defer testing.allocator.free(cwd);

    var g: Generators = .init(testing.allocator, io);
    defer g.deinit();
    const now: Io.Timestamp = .{ .nanoseconds = 0 };

    const br = g.get(.git_branches, cwd, now);
    try expectNames(br, &.{ "feature/x", "main", "old", "origin/main", "upstream/dev" });
    for (br) |it| if (std.mem.eql(u8, it.name, "main")) {
        try testing.expectEqualStrings("Current branch", it.description);
    };

    try expectNames(g.get(.git_tags, cwd, now), &.{ "v0", "v1" });
    try expectNames(g.get(.git_remotes, cwd, now), &.{ "origin", "upstream" });

    // Outside a repo: nothing.
    try testing.expectEqual(@as(usize, 0), g.get(.git_branches, "/", now).len);
}

test "autocomplete generators: git worktree file and commondir" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "main/.git/refs/heads");
    try d.createDirPath(io, "main/.git/worktrees/wt");
    try d.createDirPath(io, "wt");
    try d.writeFile(io, .{ .sub_path = "main/.git/refs/heads/trunk", .data = "abc\n" });
    try d.writeFile(io, .{ .sub_path = "main/.git/refs/heads/topic", .data = "abc\n" });
    try d.writeFile(io, .{ .sub_path = "main/.git/worktrees/wt/HEAD", .data = "ref: refs/heads/topic\n" });
    try d.writeFile(io, .{ .sub_path = "main/.git/worktrees/wt/commondir", .data = "../..\n" });
    try d.writeFile(io, .{ .sub_path = "wt/.git", .data = "gitdir: ../main/.git/worktrees/wt\n" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpPath(&tmp, &buf);
    const cwd = try std.fs.path.join(testing.allocator, &.{ root, "wt" });
    defer testing.allocator.free(cwd);

    var g: Generators = .init(testing.allocator, io);
    defer g.deinit();
    const br = g.get(.git_branches, cwd, .{ .nanoseconds = 0 });
    try expectNames(br, &.{ "topic", "trunk" });
    for (br) |it| if (std.mem.eql(u8, it.name, "topic")) try testing.expect(it.boost > 2);
}

test "autocomplete generators: package.json scripts and make targets" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(io, "web/src");
    try d.writeFile(io, .{
        .sub_path = "web/package.json",
        .data = "{\"name\":\"w\",\"scripts\":{\"dev\":\"vite\",\"build\":\"vite build\",\"test\":\"vitest\"}}",
    });
    try d.writeFile(io, .{
        .sub_path = "web/Makefile",
        .data = "CC := cc\nVAR = 1\n.PHONY: all clean\nall: build\nbuild test: deps\n\t$(CC) x\n%.o: %.c\nclean:\n# comment:\ninstall::\n",
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpPath(&tmp, &buf);
    const src = try std.fs.path.join(testing.allocator, &.{ root, "web/src" });
    defer testing.allocator.free(src);
    const web = try std.fs.path.join(testing.allocator, &.{ root, "web" });
    defer testing.allocator.free(web);

    var g: Generators = .init(testing.allocator, io);
    defer g.deinit();
    const now: Io.Timestamp = .{ .nanoseconds = 0 };
    const scripts = g.get(.package_scripts, src, now);
    try expectNames(scripts, &.{ "build", "dev", "test" });
    for (scripts) |it| if (std.mem.eql(u8, it.name, "build")) try testing.expectEqualStrings("vite build", it.description);

    try expectNames(g.get(.make_targets, web, now), &.{ "all", "build", "clean", "test" });
    // The Makefile scan is cwd-only.
    try testing.expectEqual(@as(usize, 0), g.get(.make_targets, src, now).len);
}
