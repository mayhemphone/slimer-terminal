//! Glue between the core surface and the process-wide autocomplete
//! engine: lazy engine creation, the C result layout, and history
//! recording. Everything here runs on the surface's (main) thread.
const std = @import("std");
const Allocator = std.mem.Allocator;

const global = @import("../global.zig");
const unicode = @import("../unicode/main.zig");
const ac = @import("main.zig");
const Engine = @import("Engine.zig");

const log = std.log.scoped(.autocomplete);

/// The shared engine, created on first use.
var shared: ?*Engine = null;

/// Paths configured by the apprt before first use. Owned by
/// `global.alloc()`.
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
    if (shared) |e| applyPaths(e);
}

fn applyPaths(e: *Engine) void {
    const alloc = global.alloc();
    const log_path: ?[]u8 = if (data_dir) |d|
        std.fs.path.join(alloc, &.{ d, "history.log" }) catch null
    else
        null;
    defer if (log_path) |p| alloc.free(p);
    const import_path: ?[]u8 = if (histfile) |h|
        alloc.dupe(u8, h) catch null
    else if (e.home.len > 0)
        std.fs.path.join(alloc, &.{ e.home, ".zsh_history" }) catch null
    else
        null;
    defer if (import_path) |p| alloc.free(p);
    e.history.setPaths(log_path, import_path) catch {};
}

pub fn engine() ?*Engine {
    if (shared) |e| return e;
    const alloc = global.alloc();

    var home: []const u8 = "";
    var env = global.environMap() catch null;
    defer if (env) |*m| m.deinit();
    if (env) |*m| if (m.get("HOME")) |h| {
        home = h;
    };

    const e = alloc.create(Engine) catch return null;
    e.* = Engine.init(alloc, global.io(), .{ .home = home }) catch {
        alloc.destroy(e);
        return null;
    };
    applyPaths(e);
    shared = e;
    return e;
}

fn nowUnix() i64 {
    return std.Io.Timestamp.now(global.io(), .real).toSeconds();
}

/// Record the command line that is about to run (OSC 133 C).
pub fn recordCommand(state: *const ac.State, cwd: []const u8) void {
    if (!state.active or state.truncated or state.buffer.len == 0) return;
    const e = engine() orelse return;
    e.record(state.buffer, cwd, nowUnix());
}

/// Display width in cells of `bytes`, for anchoring the popup.
fn cellWidth(bytes: []const u8) u32 {
    var cols: u32 = 0;
    const view = std.unicode.Utf8View.init(bytes) catch return @intCast(bytes.len);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| cols += unicode.codepointWidth(cp);
    return cols;
}

/// Run a query for a surface's stored buffer and fill `out`. Strings in
/// `out` are owned by `state` until its next query. Returns true if
/// there is at least one suggestion.
pub fn query(state: *ac.State, alloc: Allocator, cwd: []const u8, out: *ac.CResult) bool {
    out.* = .{ .generation = state.generation };
    if (!state.active or state.buffer.len == 0) return false;
    const e = engine() orelse return false;

    const r = e.query(.{
        .buffer = state.buffer,
        .cursor = state.cursor,
        .cwd = cwd,
        .now = .now(global.io(), .awake),
        .now_unix = nowUnix(),
    }) catch |err| {
        log.warn("autocomplete: query failed err={}", .{err});
        return false;
    };

    out.replace_start = r.replace_start;
    out.replace_len = r.replace_len;
    out.replace_cols = cellWidth(state.buffer[r.replace_start_byte..r.replace_end_byte]);

    const a = state.resetQueryArena(alloc);
    var n: usize = 0;
    for (r.items) |it| {
        if (n == out.items.len) break;
        const text = a.dupe(u8, it.text) catch break;
        const display = a.dupe(u8, it.display) catch break;
        const description = a.dupe(u8, it.description) catch break;
        out.items[n] = .{
            .text = text.ptr,
            .text_len = text.len,
            .display = display.ptr,
            .display_len = display.len,
            .description = description.ptr,
            .description_len = description.len,
            .kind = @backingInt(it.kind),
            .dangerous = it.dangerous,
            .match_len = it.match_len,
        };
        n += 1;
    }
    out.count = n;
    return n > 0;
}
