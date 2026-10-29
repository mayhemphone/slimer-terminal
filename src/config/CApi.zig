const builtin = @import("builtin");
const std = @import("std");
const inputpkg = @import("../input.zig");
const global = @import("../global.zig");
const String = @import("../main_c.zig").String;

const cli = @import("../cli.zig"); // slimer: for sliceIterator
const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc()) catch |err| {
        log.err("error creating config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc().destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(global.alloc()) catch |err| {
        log.err("error cloning config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    const path_slice = std.mem.span(path);
    self.loadFile(global.alloc(), path_slice) catch |err| {
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

// slimer: Apply a single `key=value` argument to an in-memory config,
// exactly as if that line appeared in a config file. This lets the apprt
// derive per-surface configs (themes) without writing temporary files.
// Returns false if the argument is rejected or produces a diagnostic.
export fn ghostty_config_load_arg(self: *Config, arg: [*:0]const u8) bool {
    return config_load_arg_(self, global.alloc(), std.mem.span(arg)) catch |err| {
        log.warn("error loading config arg err={}", .{err});
        return false;
    };
}

// slimer: the only keys ghostty_config_load_arg accepts. Per-surface themes
// are colors only; anything that changes behavior (keybinds, clipboard,
// commands, `theme`, `config-file`) must never come through this path.
const load_arg_allowed_keys = std.StaticStringMap(void).initComptime(.{
    .{"background"},
    .{"foreground"},
    .{"cursor-color"},
    .{"cursor-text"},
    .{"selection-background"},
    .{"selection-foreground"},
    .{"palette"},
});

comptime {
    // Every allowed key must be a real config key.
    for (load_arg_allowed_keys.keys()) |k| {
        if (!@hasField(Config, k)) @compileError("unknown config key in allowlist: " ++ k);
    }
}

// slimer: see ghostty_config_load_arg. The argument must be a single
// `key=value` with an allowlisted key, no leading dashes and no newlines.
fn config_load_arg_(self: *Config, alloc: std.mem.Allocator, arg: []const u8) !bool {
    if (arg.len == 0 or arg[0] == '-') return false;
    if (std.mem.indexOfAny(u8, arg, "\r\n\x00") != null) return false;
    const eql = std.mem.indexOfScalar(u8, arg, '=') orelse return false;
    if (!load_arg_allowed_keys.has(arg[0..eql])) return false;

    const full = try std.fmt.allocPrint(alloc, "--{s}", .{arg});
    defer alloc.free(full);

    const diags_before = self._diagnostics.items().len;
    var iter = cli.args.sliceIterator(&.{full});
    try self.loadIter(alloc, &iter);
    return self._diagnostics.items().len == diags_before;
}

// slimer: read-only keybind enumeration for the shortcut overlay
// (docs/slimer/SHORTCUTS.md). Sync with ghostty_config_keybind_s.
const Keybind = extern struct {
    trigger: inputpkg.Binding.Trigger.C = .{},
    flags: inputpkg.Binding.Flags.C = 0,
};

// slimer: the number of top-level keybind entries. Valid indexes for
// ghostty_config_keybind_at are 0 ..< count.
export fn ghostty_config_keybind_count(self: *Config) usize {
    return self.keybind.set.bindings.count();
}

// slimer: read one top-level keybind. Writes the trigger and flags to `out`
// and the action (in config syntax, e.g. `goto_split:left`) to `buf` as a
// NUL-terminated string, truncated to fit. Returns false for an index out of
// range, a sequence leader (`a>b`), or a zero-length buffer. Chained bindings
// report their first action. Nothing in the config is modified.
export fn ghostty_config_keybind_at(
    self: *Config,
    index: usize,
    out: *Keybind,
    buf: [*]u8,
    buf_len: usize,
) bool {
    return config_keybind_at_(self, index, out, buf[0..buf_len]);
}

fn config_keybind_at_(
    self: *const Config,
    index: usize,
    out: *Keybind,
    buf: []u8,
) bool {
    if (buf.len == 0) return false;
    buf[0] = 0;
    const set = &self.keybind.set;
    if (index >= set.bindings.count()) return false;
    const trigger = set.bindings.keys()[index];
    const action: inputpkg.Binding.Action, const flags = switch (set.bindings.values()[index]) {
        .leader => return false,
        .leaf => |leaf| .{ leaf.action, leaf.flags },
        .leaf_chained => |leaf| leaf: {
            if (leaf.actions.items.len == 0) return false;
            break :leaf .{ leaf.actions.items[0], leaf.flags };
        },
    };

    // Truncation is fine: the text is only ever displayed.
    var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    switch (action) {
        // Internal action whose value can't be formatted.
        .cursor_key => writer.writeAll(@tagName(action)) catch {},
        else => writer.print("{f}", .{action}) catch {},
    }
    buf[writer.end] = 0;

    out.* = .{ .trigger = trigger.cval(), .flags = flags.cval() };
    return true;
}

export fn ghostty_config_open_path() String {
    const path = edit.openPath(global.alloc()) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "ghostty_config_trigger: default keybind" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Default commands should be fetchable through config_trigger_
    {
        const trigger = try config_trigger_(&cfg, "open_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    {
        const trigger = try config_trigger_(&cfg, "reload_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    // Performable bindings are not tracked in the reverse map,
    // so config_trigger_ should return a default (empty) trigger.
    if (comptime builtin.target.os.tag.isDarwin()) {
        const next = try config_trigger_(&cfg, "navigate_search:next");
        try testing.expectEqual(.physical, next.tag);
        try testing.expectEqual(.unidentified, next.key.physical);

        const prev = try config_trigger_(&cfg, "navigate_search:previous");
        try testing.expectEqual(.physical, prev.tag);
        try testing.expectEqual(.unidentified, prev.key.physical);
    }
    {
        const trigger = try config_trigger_(&cfg, "adjust_selection:left");
        try testing.expectEqual(.physical, trigger.tag);
        try testing.expectEqual(.unidentified, trigger.key.physical);
    }
}

test "slimer: ghostty_config_load_arg applies a color" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    try testing.expect(try config_load_arg_(&cfg, alloc, "background=#112233"));
    try testing.expectEqual(@as(u8, 0x11), cfg.background.r);
    try testing.expectEqual(@as(u8, 0x22), cfg.background.g);
    try testing.expectEqual(@as(u8, 0x33), cfg.background.b);
    try testing.expect(cfg._diagnostics.empty());

    // Later args override earlier ones, like config file lines.
    try testing.expect(try config_load_arg_(&cfg, alloc, "background=#445566"));
    try testing.expectEqual(@as(u8, 0x44), cfg.background.r);

    // Palette entries and the other color keys are allowed.
    try testing.expect(try config_load_arg_(&cfg, alloc, "palette=1=#AA0000"));
    try testing.expectEqual(@as(u8, 0xAA), cfg.palette.value[1].r);
    try testing.expect(try config_load_arg_(&cfg, alloc, "selection-foreground=#010203"));
    try testing.expect(try config_load_arg_(&cfg, alloc, "cursor-text=#010203"));
}

test "slimer: ghostty_config_load_arg rejects bad input" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    // Newlines can never smuggle a second key.
    const font_size_before = cfg.@"font-size";
    try testing.expect(!try config_load_arg_(&cfg, alloc, "background=#112233\nfont-size=99"));
    try testing.expectEqual(font_size_before, cfg.@"font-size");

    // Empty, dash-prefixed, and unknown keys are rejected.
    try testing.expect(!try config_load_arg_(&cfg, alloc, ""));
    try testing.expect(!try config_load_arg_(&cfg, alloc, "--background=#112233"));
    try testing.expect(!try config_load_arg_(&cfg, alloc, "not-a-real-key=1"));

    // Only color keys are allowed; behavior-changing keys are refused.
    try testing.expect(!try config_load_arg_(&cfg, alloc, "theme=Nord"));
    try testing.expect(!try config_load_arg_(&cfg, alloc, "config-file=/tmp/x"));
    try testing.expect(!try config_load_arg_(&cfg, alloc, "keybind=enter=text:rm"));
    try testing.expect(!try config_load_arg_(&cfg, alloc, "clipboard-read=allow"));
    try testing.expect(!try config_load_arg_(&cfg, alloc, "background"));
    try testing.expect(cfg.theme == null);

    // Invalid values produce a diagnostic and return false.
    try testing.expect(!try config_load_arg_(&cfg, alloc, "background=notacolor"));
    try testing.expect(!cfg._diagnostics.empty());
}

test "slimer: ghostty_config_keybind_at enumerates bindings" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it = cli.args.sliceIterator(&.{
        "--keybind=clear",
        "--keybind=global:cmd+backquote=toggle_quick_terminal",
        "--keybind=ctrl+a>n=new_tab",
        "--keybind=cmd+shift+e=equalize_splits",
        "--keybind=chain=goto_split:left",
        "--keybind=ctrl+t=text:hello world",
    });
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();

    const count = ghostty_config_keybind_count(&cfg);
    try testing.expectEqual(@as(usize, 4), count);

    var buf: [64]u8 = undefined;
    var out: Keybind = .{};
    var found_global = false;
    var found_chain = false;
    var found_text = false;
    var leaders: usize = 0;
    for (0..count) |i| {
        if (!ghostty_config_keybind_at(&cfg, i, &out, &buf, buf.len)) {
            leaders += 1;
            continue;
        }
        const action = std.mem.sliceTo(&buf, 0);
        if (std.mem.eql(u8, action, "toggle_quick_terminal")) {
            found_global = true;
            try testing.expect((inputpkg.Binding.Flags{ .global = true }).cval() & out.flags != 0);
            try testing.expectEqual(.physical, out.trigger.tag);
            try testing.expectEqual(inputpkg.Key.backquote, out.trigger.key.physical);
            try testing.expect(out.trigger.mods.super);
        } else if (std.mem.eql(u8, action, "equalize_splits")) {
            // A chained binding reports its first action.
            found_chain = true;
            try testing.expect(out.trigger.mods.shift);
            try testing.expect(out.trigger.mods.super);
        } else if (std.mem.eql(u8, action, "text:hello world")) {
            found_text = true;
            try testing.expect(out.trigger.mods.ctrl);
        } else {
            return error.UnexpectedAction;
        }
    }
    try testing.expect(found_global and found_chain and found_text);
    // `ctrl+a>n` is a sequence: its leader is skipped.
    try testing.expectEqual(@as(usize, 1), leaders);

    // Out of range and empty buffers are refused.
    try testing.expect(!ghostty_config_keybind_at(&cfg, count, &out, &buf, buf.len));
    try testing.expect(!ghostty_config_keybind_at(&cfg, 0, &out, &buf, 0));
}

test "slimer: ghostty_config_keybind_at truncates the action" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    var it = cli.args.sliceIterator(&.{
        "--keybind=clear",
        "--keybind=ctrl+t=text:0123456789abcdef",
    });
    try cfg.loadIter(alloc, &it);
    try cfg.finalize();

    var buf: [8]u8 = undefined;
    var out: Keybind = .{};
    try testing.expect(ghostty_config_keybind_at(&cfg, 0, &out, &buf, buf.len));
    try testing.expectEqualStrings("text:01", std.mem.sliceTo(&buf, 0));
}

test "slimer: ghostty_config_keybind_at covers the defaults" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    try cfg.finalize();

    // Every default binding formats without crashing, and the split
    // navigation bindings that have no menu item are present.
    var buf: [128]u8 = undefined;
    var out: Keybind = .{};
    var saw_goto_split = false;
    for (0..ghostty_config_keybind_count(&cfg)) |i| {
        if (!ghostty_config_keybind_at(&cfg, i, &out, &buf, buf.len)) continue;
        const action = std.mem.sliceTo(&buf, 0);
        try testing.expect(action.len > 0);
        if (std.mem.startsWith(u8, action, "goto_split:")) saw_goto_split = true;
    }
    try testing.expect(saw_goto_split);
}
