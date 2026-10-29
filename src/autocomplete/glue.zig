//! Glue between the core surface and the process-wide autocomplete
//! worker: lazy worker creation, async queries delivered through the
//! surface mailbox, the C result layout, and history recording.
//!
//! Everything in this file is called on the surface's (main) thread; the
//! engine itself only ever runs on the worker thread.
const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");
const apprt = @import("../apprt.zig");
const unicode = @import("../unicode/main.zig");
const ac = @import("main.zig");
const W = ac.Worker(SurfaceSink);

const log = std.log.scoped(.autocomplete);

/// Delivers a finished query to its surface through the app mailbox. If
/// the mailbox is full the result is dropped; the next keystroke queries
/// again.
pub const SurfaceSink = struct {
    mailbox: apprt.surface.Mailbox,

    pub fn deliver(self: SurfaceSink, r: *ac.OwnedResult) void {
        if (self.mailbox.push(.{ .autocomplete_result = r }, .{ .instant = {} }) == 0) {
            r.destroy();
        }
    }
};

/// The shared worker, created on first use.
var worker: ?*W = null;

/// Paths configured by the apprt before the worker exists.
var data_dir: ?[]u8 = null;
var histfile: ?[]u8 = null;

/// Set where history lives. `dir` is the Slimer data directory
/// (history.log goes inside it); `zsh_history` overrides the zsh import
/// source (default `~/.zsh_history`). Empty strings mean "default" for
/// the import and "no persistence" for the data dir. Takes effect for
/// loading only before the first query.
pub fn configure(dir: []const u8, zsh_history: []const u8) void {
    const alloc = global.alloc();
    if (data_dir) |d| alloc.free(d);
    if (histfile) |h| alloc.free(h);
    data_dir = if (dir.len > 0) alloc.dupe(u8, dir) catch null else null;
    histfile = if (zsh_history.len > 0) alloc.dupe(u8, zsh_history) catch null else null;
    if (worker) |w| applyPaths(w);
}

fn applyPaths(w: *W) void {
    const alloc = global.alloc();
    const log_path: ?[]u8 = if (data_dir) |d|
        std.fs.path.join(alloc, &.{ d, "history.log" }) catch null
    else
        null;
    defer if (log_path) |p| alloc.free(p);
    const import_path: ?[]u8 = if (histfile) |h|
        alloc.dupe(u8, h) catch null
    else if (w.engine.home.len > 0)
        std.fs.path.join(alloc, &.{ w.engine.home, ".zsh_history" }) catch null
    else
        null;
    defer if (import_path) |p| alloc.free(p);
    w.submitPaths(log_path, import_path);
}

fn getWorker() ?*W {
    if (worker) |w| return w;
    const alloc = global.alloc();

    var home: []const u8 = "";
    var env = global.environMap() catch null;
    defer if (env) |*m| m.deinit();
    if (env) |*m| if (m.get("HOME")) |h| {
        home = h;
    };

    const w = W.create(alloc, global.io(), .{ .home = home }) catch |err| {
        log.warn("autocomplete: cannot start worker err={}", .{err});
        return null;
    };
    applyPaths(w);
    worker = w;
    return w;
}

/// Record the command line that is about to run (OSC 133 C).
pub fn recordCommand(line: []const u8, cwd: []const u8) void {
    if (line.len == 0) return;
    const w = getWorker() orelse return;
    w.submitRecord(line, cwd);
}

/// Forget queued work for a surface that is going away.
pub fn cancel(owner: u64) void {
    if (worker) |w| w.cancel(owner);
}

/// Display width in cells of `bytes`, for anchoring the popup.
fn cellWidth(bytes: []const u8) u32 {
    var cols: u32 = 0;
    const view = std.unicode.Utf8View.init(bytes) catch return @intCast(bytes.len);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| cols += unicode.codepointWidth(cp);
    return cols;
}

/// Fill `out` for a surface. If the worker has delivered a result for the
/// current generation, copy it (strings stay owned by `state`) and return
/// true when it has items. Otherwise queue a query for this generation
/// (once), set `out.pending`, and return false; the surface emits another
/// update when the result arrives.
pub fn query(
    state: *ac.State,
    owner: u64,
    mailbox: apprt.surface.Mailbox,
    cwd: []const u8,
    out: *ac.CResult,
) bool {
    out.* = .{ .generation = state.generation };
    if (!state.active or state.buffer.len == 0) return false;

    if (state.result) |r| if (r.generation == state.generation) {
        fill(state, r, out);
        return out.count > 0;
    };

    if (state.requested != state.generation) {
        const w = getWorker() orelse return false;
        w.submitQuery(.{
            .owner = owner,
            .generation = state.generation,
            .buffer = state.buffer,
            .cursor = state.cursor,
            .cwd = cwd,
            .sink = .{ .mailbox = mailbox },
        });
        state.requested = state.generation;
    }
    out.pending = true;
    return false;
}

fn fill(state: *const ac.State, r: *const ac.OwnedResult, out: *ac.CResult) void {
    out.replace_start = r.replace_start;
    out.replace_len = r.replace_len;
    const end = @min(r.replace_end_byte, state.buffer.len);
    const start = @min(r.replace_start_byte, end);
    out.replace_cols = cellWidth(state.buffer[start..end]);
    var n: usize = 0;
    for (r.items) |it| {
        if (n == out.items.len) break;
        out.items[n] = .{
            .text = it.text.ptr,
            .text_len = it.text.len,
            .display = it.display.ptr,
            .display_len = it.display.len,
            .description = it.description.ptr,
            .description_len = it.description.len,
            .kind = @backingInt(it.kind),
            .dangerous = it.dangerous,
            .match_len = it.match_len,
        };
        n += 1;
    }
    out.count = n;
}
