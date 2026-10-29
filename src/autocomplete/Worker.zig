//! The autocomplete worker: one background thread that owns the shared
//! `Engine`, so engine queries and all filesystem and history I/O stay off
//! the main thread.
//!
//! Jobs run in order. Queries are coalesced per owner (surface): a new
//! query replaces one still waiting in the queue, so a burst of keystrokes
//! costs one query. Results are handed to a `Sink` (the surface mailbox in
//! the app), which owns them from then on; the surface drops a result
//! whose generation is no longer current.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Engine = @import("Engine.zig");

const log = std.log.scoped(.autocomplete);

/// A query result, owned by whoever it was delivered to. Strings point
/// into its arena.
pub const OwnedResult = struct {
    alloc: Allocator,
    arena: std.heap.ArenaAllocator,
    owner: u64,
    generation: u64,
    items: []const Engine.Suggestion = &.{},
    replace_start: u32 = 0,
    replace_len: u32 = 0,
    replace_start_byte: usize = 0,
    replace_end_byte: usize = 0,

    pub fn destroy(self: *OwnedResult) void {
        self.arena.deinit();
        self.alloc.destroy(self);
    }
};

pub fn Worker(comptime Sink: type) type {
    return struct {
        const Self = @This();

        pub const Query = struct {
            owner: u64,
            generation: u64,
            buffer: []const u8,
            cursor: u32,
            cwd: []const u8,
            sink: Sink,
        };

        const Job = union(enum) {
            query: struct {
                owner: u64,
                generation: u64,
                buffer: []u8,
                cursor: u32,
                cwd: []u8,
                sink: Sink,
            },
            record: struct { line: []u8, cwd: []u8 },
            paths: struct { log_path: ?[]u8, import_path: ?[]u8 },
            /// Signals the event when reached (see `flush`).
            barrier: *Io.Event,
            /// Test hook: block the worker until the event is set.
            hold: *Io.Event,

            fn deinit(self: Job, alloc: Allocator) void {
                switch (self) {
                    .query => |q| {
                        alloc.free(q.buffer);
                        alloc.free(q.cwd);
                    },
                    .record => |r| {
                        alloc.free(r.line);
                        alloc.free(r.cwd);
                    },
                    .paths => |p| {
                        if (p.log_path) |v| alloc.free(v);
                        if (p.import_path) |v| alloc.free(v);
                    },
                    .barrier, .hold => {},
                }
            }
        };

        alloc: Allocator,
        io: Io,
        engine: Engine,
        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        jobs: std.ArrayList(Job) = .empty,
        stopping: bool = false,
        thread: ?std.Thread = null,

        pub fn create(alloc: Allocator, io: Io, opts: Engine.Options) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);
            self.* = .{
                .alloc = alloc,
                .io = io,
                .engine = try Engine.init(alloc, io, opts),
            };
            errdefer self.engine.deinit();
            self.thread = try std.Thread.spawn(.{}, run, .{self});
            self.thread.?.setName(io, "autocomplete") catch {};
            return self;
        }

        /// Stop the thread, drop queued jobs and free everything.
        pub fn destroy(self: *Self) void {
            {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                self.stopping = true;
                self.cond.signal(self.io);
            }
            if (self.thread) |t| t.join();
            for (self.jobs.items) |j| j.deinit(self.alloc);
            self.jobs.deinit(self.alloc);
            self.engine.deinit();
            self.alloc.destroy(self);
        }

        fn push(self: *Self, job: Job) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.jobs.append(self.alloc, job) catch {
                job.deinit(self.alloc);
                return;
            };
            self.cond.signal(self.io);
        }

        /// Queue a query, replacing one from the same owner that hasn't
        /// started yet. The inputs are copied.
        pub fn submitQuery(self: *Self, q: Query) void {
            const buffer = self.alloc.dupe(u8, q.buffer) catch return;
            const cwd = self.alloc.dupe(u8, q.cwd) catch {
                self.alloc.free(buffer);
                return;
            };
            const job: Job = .{ .query = .{
                .owner = q.owner,
                .generation = q.generation,
                .buffer = buffer,
                .cursor = q.cursor,
                .cwd = cwd,
                .sink = q.sink,
            } };

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.jobs.items) |*existing| switch (existing.*) {
                .query => |old| if (old.owner == q.owner) {
                    existing.deinit(self.alloc);
                    existing.* = job;
                    self.cond.signal(self.io);
                    return;
                },
                else => {},
            };
            self.jobs.append(self.alloc, job) catch {
                job.deinit(self.alloc);
                return;
            };
            self.cond.signal(self.io);
        }

        /// Drop queued queries for `owner` (the surface is going away).
        pub fn cancel(self: *Self, owner: u64) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var i: usize = 0;
            while (i < self.jobs.items.len) {
                const j = self.jobs.items[i];
                if (j == .query and j.query.owner == owner) {
                    j.deinit(self.alloc);
                    _ = self.jobs.orderedRemove(i);
                } else i += 1;
            }
        }

        pub fn submitRecord(self: *Self, line: []const u8, cwd: []const u8) void {
            const l = self.alloc.dupe(u8, line) catch return;
            const c = self.alloc.dupe(u8, cwd) catch {
                self.alloc.free(l);
                return;
            };
            self.push(.{ .record = .{ .line = l, .cwd = c } });
        }

        pub fn submitPaths(self: *Self, log_path: ?[]const u8, import_path: ?[]const u8) void {
            const lp: ?[]u8 = if (log_path) |p| self.alloc.dupe(u8, p) catch return else null;
            const ip: ?[]u8 = if (import_path) |p| self.alloc.dupe(u8, p) catch {
                if (lp) |v| self.alloc.free(v);
                return;
            } else null;
            self.push(.{ .paths = .{ .log_path = lp, .import_path = ip } });
        }

        /// Wait until every job queued before this call has run.
        pub fn flush(self: *Self) void {
            var ev: Io.Event = .unset;
            self.push(.{ .barrier = &ev });
            ev.waitUncancelable(self.io);
        }

        fn run(self: *Self) void {
            while (true) {
                const job: Job = job: {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    while (self.jobs.items.len == 0 and !self.stopping) {
                        self.cond.waitUncancelable(self.io, &self.mutex);
                    }
                    if (self.stopping) return;
                    break :job self.jobs.orderedRemove(0);
                };
                self.process(job);
                job.deinit(self.alloc);
            }
        }

        fn process(self: *Self, job: Job) void {
            switch (job) {
                .query => |q| {
                    const r = self.engine.query(.{
                        .buffer = q.buffer,
                        .cursor = q.cursor,
                        .cwd = q.cwd,
                        .now = .now(self.io, .awake),
                        .now_unix = Io.Timestamp.now(self.io, .real).toSeconds(),
                    }) catch |err| {
                        log.warn("autocomplete: query failed err={}", .{err});
                        return;
                    };
                    const owned = copyResult(self.alloc, q.owner, q.generation, r) catch return;
                    q.sink.deliver(owned);
                },
                .record => |rec| self.engine.record(
                    rec.line,
                    rec.cwd,
                    Io.Timestamp.now(self.io, .real).toSeconds(),
                ),
                .paths => |p| {
                    self.engine.history.setPaths(p.log_path, p.import_path) catch {};
                },
                .barrier => |ev| ev.set(self.io),
                .hold => |ev| ev.waitUncancelable(self.io),
            }
        }
    };
}

fn copyResult(alloc: Allocator, owner: u64, generation: u64, r: Engine.Result) Allocator.Error!*OwnedResult {
    const out = try alloc.create(OwnedResult);
    out.* = .{
        .alloc = alloc,
        .arena = .init(alloc),
        .owner = owner,
        .generation = generation,
        .replace_start = r.replace_start,
        .replace_len = r.replace_len,
        .replace_start_byte = r.replace_start_byte,
        .replace_end_byte = r.replace_end_byte,
    };
    errdefer out.destroy();
    const a = out.arena.allocator();
    const items = try a.alloc(Engine.Suggestion, r.items.len);
    for (r.items, items) |src, *dst| {
        dst.* = src;
        dst.text = try a.dupe(u8, src.text);
        dst.display = try a.dupe(u8, src.display);
        dst.description = try a.dupe(u8, src.description);
    }
    out.items = items;
    return out;
}

const testing = std.testing;

const TestSink = struct {
    box: *Box,

    const Box = struct {
        mutex: Io.Mutex = .init,
        results: std.ArrayList(*OwnedResult) = .empty,
    };

    pub fn deliver(self: TestSink, r: *OwnedResult) void {
        self.box.mutex.lockUncancelable(testing.io);
        defer self.box.mutex.unlock(testing.io);
        self.box.results.append(testing.allocator, r) catch r.destroy();
    }
};

const test_sources = [_]@import("Spec.zig").Source{
    .{ .key = "git", .text =
    \\{"name":["git"],"subcommands":[{"name":["status"]},{"name":["stash"]},{"name":["switch"]}]}
    },
};

test "autocomplete worker: queries run off-thread, coalesce per owner, records" {
    var box: TestSink.Box = .{};
    defer {
        for (box.results.items) |r| r.destroy();
        box.results.deinit(testing.allocator);
    }
    const W = Worker(TestSink);
    const w = try W.create(testing.allocator, testing.io, .{
        .sources = &test_sources,
        .index = "{}",
    });
    defer w.destroy();
    w.submitPaths(null, null);
    w.flush();

    // Park the worker so the next queries queue up.
    var release: Io.Event = .unset;
    w.push(.{ .hold = &release });
    w.submitQuery(.{ .owner = 1, .generation = 1, .buffer = "git st", .cursor = 6, .cwd = "", .sink = .{ .box = &box } });
    w.submitQuery(.{ .owner = 7, .generation = 5, .buffer = "git", .cursor = 3, .cwd = "", .sink = .{ .box = &box } });
    // Replaces owner 1's queued query in place.
    w.submitQuery(.{ .owner = 1, .generation = 2, .buffer = "git sw", .cursor = 6, .cwd = "", .sink = .{ .box = &box } });
    w.submitQuery(.{ .owner = 9, .generation = 1, .buffer = "git", .cursor = 3, .cwd = "", .sink = .{ .box = &box } });
    w.cancel(9);
    w.submitRecord("git stash", "/x");
    release.set(testing.io);
    w.flush();

    try testing.expectEqual(@as(usize, 2), box.results.items.len);
    try testing.expect(box.results.items.len >= 2);
    // Owner 1 got only the latest generation.
    var last_owner1: ?*OwnedResult = null;
    var owner7: ?*OwnedResult = null;
    for (box.results.items) |r| {
        if (r.owner == 1) last_owner1 = r;
        if (r.owner == 7) owner7 = r;
    }
    try testing.expectEqual(@as(u64, 2), last_owner1.?.generation);
    try testing.expectEqualStrings("switch", last_owner1.?.items[0].text);
    try testing.expectEqual(@as(u32, 4), last_owner1.?.replace_start);
    try testing.expect(owner7 != null);
    // The record ran on the worker.
    try testing.expect(w.engine.history.lineStat("git stash") != null);

    for (box.results.items) |r| try testing.expect(r.owner != 9);
}
