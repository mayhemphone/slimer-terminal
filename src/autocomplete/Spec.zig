//! Completion specs in the `tools/autocomplete-specs` converter format,
//! and a lazy, LRU-cached registry over the specs embedded in the binary.
//!
//! The JSON is parsed into the plain structs below on first use of a CLI
//! (one arena per spec) and kept in a 64-entry LRU cache. Generator
//! `script`s are never run here: at parse time each generator is mapped
//! to a native generator kind when its script is one we reimplement
//! (git refs, package.json scripts, make targets), otherwise it is inert.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const log = std.log.scoped(.autocomplete);

pub const Templates = packed struct(u8) {
    filepaths: bool = false,
    folders: bool = false,
    history: bool = false,
    help: bool = false,
    _pad: u4 = 0,

    pub fn any(self: Templates) bool {
        return self.filepaths or self.folders;
    }
};

/// Generators we implement natively, without running anything.
pub const Native = enum {
    git_branches,
    git_remotes,
    git_tags,
    package_scripts,
    make_targets,
};

pub const Generator = struct {
    native: ?Native = null,
    templates: Templates = .{},
};

pub const Suggestion = struct {
    names: []const []const u8,
    description: []const u8 = "",
    priority: f32 = 50,
    dangerous: bool = false,
    hidden: bool = false,
};

pub const Arg = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    optional: bool = false,
    variadic: bool = false,
    is_command: bool = false,
    is_script: bool = false,
    dangerous: bool = false,
    templates: Templates = .{},
    suggestions: []const Suggestion = &.{},
    generators: []const Generator = &.{},
};

pub const Option = struct {
    names: []const []const u8,
    description: []const u8 = "",
    args: []const Arg = &.{},
    persistent: bool = false,
    dangerous: bool = false,
    repeatable: bool = false,
    /// `=` for `requiresSeparator: true`, the separator string, or null.
    separator: ?[]const u8 = null,
    hidden: bool = false,
    priority: f32 = 50,
    exclusive_on: []const []const u8 = &.{},
};

pub const Subcommand = struct {
    names: []const []const u8,
    description: []const u8 = "",
    hidden: bool = false,
    dangerous: bool = false,
    requires_subcommand: bool = false,
    priority: f32 = 50,
    load_spec: ?[]const u8 = null,
    subcommands: []const Subcommand = &.{},
    options: []const Option = &.{},
    args: []const Arg = &.{},
};

pub const ParseError = error{InvalidSpec} || Allocator.Error;

/// Parse one spec document. Strings either alias `text` (when it
/// outlives the result, as embedded data does) or are copied into
/// `alloc`. Everything returned is owned by `alloc`; use an arena.
pub fn parse(alloc: Allocator, text: []const u8) ParseError!Subcommand {
    var tmp: std.heap.ArenaAllocator = .init(alloc);
    defer tmp.deinit();
    const value = json.parseFromSliceLeaky(json.Value, tmp.allocator(), text, .{}) catch
        return error.InvalidSpec;
    const c: Converter = .{ .alloc = alloc, .text = text };
    return c.subcommand(value, 0);
}

const max_depth = 32;

const Converter = struct {
    alloc: Allocator,
    text: []const u8,

    fn str(self: Converter, s: []const u8) Allocator.Error![]const u8 {
        const base = @intFromPtr(self.text.ptr);
        const p = @intFromPtr(s.ptr);
        if (p >= base and p + s.len <= base + self.text.len) return s;
        return self.alloc.dupe(u8, s);
    }

    fn obj(v: json.Value) ParseError!json.ObjectMap {
        return switch (v) {
            .object => |o| o,
            else => error.InvalidSpec,
        };
    }

    fn getStr(self: Converter, o: json.ObjectMap, key: []const u8) ParseError![]const u8 {
        const v = o.get(key) orelse return "";
        return switch (v) {
            .string => |s| try self.str(s),
            else => error.InvalidSpec,
        };
    }

    fn getBool(o: json.ObjectMap, key: []const u8) bool {
        const v = o.get(key) orelse return false;
        return switch (v) {
            .bool => |b| b,
            else => false,
        };
    }

    fn getNum(o: json.ObjectMap, key: []const u8, default: f32) f32 {
        const v = o.get(key) orelse return default;
        return switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => default,
        };
    }

    fn names(self: Converter, o: json.ObjectMap) ParseError![]const []const u8 {
        const v = o.get("name") orelse return error.InvalidSpec;
        return self.strList(v);
    }

    fn strList(self: Converter, v: json.Value) ParseError![]const []const u8 {
        switch (v) {
            .string => |s| {
                const out = try self.alloc.alloc([]const u8, 1);
                out[0] = try self.str(s);
                return out;
            },
            .array => |arr| {
                const out = try self.alloc.alloc([]const u8, arr.items.len);
                for (arr.items, out) |item, *dst| dst.* = switch (item) {
                    .string => |s| try self.str(s),
                    else => return error.InvalidSpec,
                };
                return out;
            },
            else => return error.InvalidSpec,
        }
    }

    fn templates(o: json.ObjectMap) Templates {
        var t: Templates = .{};
        const v = o.get("template") orelse return t;
        const items: []const json.Value = switch (v) {
            .array => |a| a.items,
            .string => @as(*const [1]json.Value, &v),
            else => return t,
        };
        for (items) |item| switch (item) {
            .string => |s| {
                if (std.mem.eql(u8, s, "filepaths")) t.filepaths = true;
                if (std.mem.eql(u8, s, "folders")) t.folders = true;
                if (std.mem.eql(u8, s, "history")) t.history = true;
                if (std.mem.eql(u8, s, "help")) t.help = true;
            },
            else => {},
        };
        return t;
    }

    fn list(v: ?json.Value) []const json.Value {
        const val = v orelse return &.{};
        return switch (val) {
            .array => |a| a.items,
            else => &.{},
        };
    }

    fn subcommand(self: Converter, v: json.Value, depth: usize) ParseError!Subcommand {
        if (depth > max_depth) return error.InvalidSpec;
        const o = try obj(v);

        const subs_v = list(o.get("subcommands"));
        const subs = try self.alloc.alloc(Subcommand, subs_v.len);
        for (subs_v, subs) |sv, *dst| dst.* = try self.subcommand(sv, depth + 1);

        const opts_v = list(o.get("options"));
        const opts = try self.alloc.alloc(Option, opts_v.len);
        for (opts_v, opts) |ov, *dst| dst.* = try self.option(ov);

        return .{
            .names = try self.names(o),
            .description = try self.getStr(o, "description"),
            .hidden = getBool(o, "hidden"),
            .dangerous = getBool(o, "isDangerous"),
            .requires_subcommand = getBool(o, "requiresSubcommand"),
            .priority = getNum(o, "priority", 50),
            .load_spec = if (o.get("loadSpec")) |ls| switch (ls) {
                .string => |s| try self.str(s),
                else => null,
            } else null,
            .subcommands = subs,
            .options = opts,
            .args = try self.args(o.get("args")),
        };
    }

    fn option(self: Converter, v: json.Value) ParseError!Option {
        const o = try obj(v);
        const sep: ?[]const u8 = if (o.get("requiresSeparator")) |rs| switch (rs) {
            .bool => |b| if (b) "=" else null,
            .string => |s| try self.str(s),
            else => null,
        } else null;
        return .{
            .names = try self.names(o),
            .description = try self.getStr(o, "description"),
            .args = try self.args(o.get("args")),
            .persistent = getBool(o, "isPersistent"),
            .dangerous = getBool(o, "isDangerous"),
            .repeatable = if (o.get("isRepeatable")) |r| switch (r) {
                .bool => |b| b,
                .integer => |n| n > 1,
                else => false,
            } else false,
            .separator = sep,
            .hidden = getBool(o, "hidden"),
            .priority = getNum(o, "priority", 50),
            .exclusive_on = if (o.get("exclusiveOn")) |e| try self.strList(e) else &.{},
        };
    }

    fn args(self: Converter, v: ?json.Value) ParseError![]const Arg {
        const val = v orelse return &.{};
        const items: []const json.Value = switch (val) {
            .array => |a| a.items,
            .object => @as(*const [1]json.Value, &val),
            else => return error.InvalidSpec,
        };
        const out = try self.alloc.alloc(Arg, items.len);
        for (items, out) |item, *dst| dst.* = try self.arg(item);
        return out;
    }

    fn arg(self: Converter, v: json.Value) ParseError!Arg {
        const o = try obj(v);

        const sugg_v = list(o.get("suggestions"));
        const sugg = try self.alloc.alloc(Suggestion, sugg_v.len);
        var n_sugg: usize = 0;
        for (sugg_v) |sv| {
            const so = switch (sv) {
                .object => |so| so,
                // A bare string suggestion is allowed by Fig; accept it.
                .string => |s| {
                    const nm = try self.alloc.alloc([]const u8, 1);
                    nm[0] = try self.str(s);
                    sugg[n_sugg] = .{ .names = nm };
                    n_sugg += 1;
                    continue;
                },
                else => return error.InvalidSpec,
            };
            sugg[n_sugg] = .{
                .names = try self.names(so),
                .description = try self.getStr(so, "description"),
                .priority = getNum(so, "priority", 50),
                .dangerous = getBool(so, "isDangerous"),
                .hidden = getBool(so, "hidden"),
            };
            n_sugg += 1;
        }

        const gen_v = list(o.get("generators"));
        const gens = try self.alloc.alloc(Generator, gen_v.len);
        for (gen_v, gens) |gv, *dst| {
            const go = try obj(gv);
            dst.* = .{
                .native = nativeFor(go.get("script")),
                .templates = templates(go),
            };
        }

        return .{
            .name = try self.getStr(o, "name"),
            .description = try self.getStr(o, "description"),
            .optional = getBool(o, "isOptional"),
            .variadic = getBool(o, "isVariadic"),
            .is_command = getBool(o, "isCommand"),
            .is_script = getBool(o, "isScript"),
            .dangerous = getBool(o, "isDangerous"),
            .templates = templates(o),
            .suggestions = sugg[0..n_sugg],
            .generators = gens,
        };
    }
};

/// Map a generator script (argv data, never run) onto a native
/// generator. Matches the scripts the Fig corpus uses for these.
pub fn nativeFor(script: ?json.Value) ?Native {
    const v = script orelse return null;
    const argv = switch (v) {
        .array => |a| a.items,
        else => return null,
    };
    var has = struct {
        git: bool = false,
        branch: bool = false,
        remote: bool = false,
        tag: bool = false,
        package_json: bool = false,
        make: bool = false,
    }{};
    for (argv) |item| {
        const s = switch (item) {
            .string => |s| s,
            else => continue,
        };
        var it = std.mem.tokenizeAny(u8, s, " \t\n;|&()'\"");
        while (it.next()) |w| {
            if (std.mem.eql(u8, w, "git")) has.git = true;
            if (std.mem.eql(u8, w, "branch") or std.mem.eql(u8, w, "for-each-ref") or
                std.mem.startsWith(u8, w, "refs/heads")) has.branch = true;
            if (std.mem.eql(u8, w, "remote")) has.remote = true;
            if (std.mem.eql(u8, w, "tag")) has.tag = true;
            if (std.mem.indexOf(u8, w, "package.json") != null) has.package_json = true;
            if (std.mem.eql(u8, w, "make") or std.mem.eql(u8, w, "Makefile")) has.make = true;
        }
    }
    if (has.package_json) return .package_scripts;
    if (has.git and has.branch) return .git_branches;
    if (has.git and has.remote) return .git_remotes;
    if (has.git and has.tag) return .git_tags;
    if (has.make) return .make_targets;
    return null;
}

/// One embedded spec file: its key (path under `specs/` without
/// `.json`) and contents.
pub const Source = struct {
    key: []const u8,
    text: []const u8,
};

/// The specs compiled into the binary. Keep in sync with
/// `data/specs/` (a test checks the count against index.json). When the
/// full Fig corpus is converted, generate this list instead.
pub const embedded = blk: {
    const keys = [_][]const u8{
        "brew", "cargo",   "cd",  "claude", "docker", "gh",
        "git",  "kubectl", "ls",  "make",   "npm",    "pnpm",
        "ssh",  "yarn",    "zig",
    };
    var out: [keys.len]Source = undefined;
    for (keys, &out) |k, *dst| dst.* = .{
        .key = k,
        .text = @embedFile("data/specs/" ++ k ++ ".json"),
    };
    const final = out;
    break :blk &final;
};

pub const embedded_index = @embedFile("data/specs/index.json");

/// Lazy, LRU-cached access to a set of spec sources. Not thread safe;
/// the engine runs on the main thread.
pub const Registry = struct {
    pub const capacity = 64;

    alloc: Allocator,
    sources: []const Source,
    by_key: std.StringHashMapUnmanaged(u32) = .empty,
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Arena for alias strings parsed out of index.json.
    meta_arena: std.heap.ArenaAllocator,
    entries: [capacity]?*Entry = @splat(null),
    tick: u64 = 0,

    const Entry = struct {
        key: []const u8,
        arena: std.heap.ArenaAllocator,
        /// null if the spec failed to parse; remembered so we don't retry
        /// on every keystroke.
        root: ?Subcommand,
        last_used: u64,
    };

    pub fn init(alloc: Allocator, sources: []const Source, index_text: []const u8) Allocator.Error!Registry {
        var self: Registry = .{
            .alloc = alloc,
            .sources = sources,
            .meta_arena = .init(alloc),
        };
        errdefer self.deinit();
        for (sources, 0..) |s, i| try self.by_key.put(alloc, s.key, @intCast(i));

        // Aliases are optional; a broken index only loses aliases.
        const ma = self.meta_arena.allocator();
        if (json.parseFromSliceLeaky(json.Value, ma, index_text, .{})) |v| {
            if (v == .object) if (v.object.get("aliases")) |al| if (al == .object) {
                var it = al.object.iterator();
                while (it.next()) |kv| switch (kv.value_ptr.*) {
                    .string => |target| if (self.by_key.contains(target)) {
                        try self.aliases.put(alloc, kv.key_ptr.*, target);
                    },
                    else => {},
                };
            };
        } else |err| {
            log.warn("autocomplete: ignoring unreadable spec index err={}", .{err});
        }
        return self;
    }

    pub fn deinit(self: *Registry) void {
        for (&self.entries) |*slot| if (slot.*) |e| {
            e.arena.deinit();
            self.alloc.destroy(e);
            slot.* = null;
        };
        self.by_key.deinit(self.alloc);
        self.aliases.deinit(self.alloc);
        self.meta_arena.deinit();
    }

    /// The spec key for a command name typed by the user, if any.
    /// Nested keys (with `/`) are only reachable through `loadSpec`.
    pub fn keyForCommand(self: *const Registry, name: []const u8) ?[]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
        if (self.by_key.getKey(name)) |k| return k;
        return self.aliases.get(name);
    }

    pub fn contains(self: *const Registry, key: []const u8) bool {
        return self.by_key.contains(key);
    }

    /// Get a parsed spec by key, parsing it on first use. The pointer is
    /// valid until 64 other specs have been loaded after it.
    pub fn get(self: *Registry, key: []const u8) ?*const Subcommand {
        self.tick += 1;
        for (self.entries) |slot| if (slot) |e| if (std.mem.eql(u8, e.key, key)) {
            e.last_used = self.tick;
            return if (e.root) |*r| r else null;
        };

        const idx = self.by_key.get(key) orelse return null;
        const src = self.sources[idx];
        const e = self.alloc.create(Entry) catch return null;
        e.* = .{
            .key = src.key,
            .arena = .init(self.alloc),
            .root = null,
            .last_used = self.tick,
        };
        e.root = parse(e.arena.allocator(), src.text) catch |err| r: {
            log.warn("autocomplete: failed to parse spec key={s} err={}", .{ key, err });
            break :r null;
        };

        // Free slot or least recently used.
        var victim: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.entries, 0..) |slot, i| {
            const used = if (slot) |s| s.last_used else 0;
            if (used < oldest) {
                oldest = used;
                victim = i;
            }
            if (slot == null) break;
        }
        if (self.entries[victim]) |old| {
            old.arena.deinit();
            self.alloc.destroy(old);
        }
        self.entries[victim] = e;
        return if (e.root) |*r| r else null;
    }

    /// Number of specs currently parsed and cached.
    pub fn cachedCount(self: *const Registry) usize {
        var n: usize = 0;
        for (self.entries) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }
};

test "autocomplete spec: parse converter output" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const text =
        \\{"name":["git"],"description":"VCS","options":[{"name":["-C"],"args":[{"name":"path","template":["folders"]}]},
        \\{"name":["--paginate","-p"],"isRepeatable":3,"requiresSeparator":true}],
        \\"subcommands":[{"name":["checkout","co"],"args":[{"name":"branch","suggestions":[{"name":["HEAD"],"priority":100}],
        \\"generators":[{"script":["git","--no-optional-locks","branch","--no-color"],"hasPostProcess":true,"hasCustom":false}]}]},
        \\{"name":["push"],"isDangerous":true,"args":{}},{"name":["lfs"],"loadSpec":"git-lfs"}]}
    ;
    const spec = try parse(arena.allocator(), text);
    try testing.expectEqualStrings("git", spec.names[0]);
    try testing.expectEqualStrings("VCS", spec.description);
    try testing.expectEqual(@as(usize, 2), spec.options.len);
    try testing.expect(spec.options[0].args[0].templates.folders);
    try testing.expect(spec.options[1].repeatable);
    try testing.expectEqualStrings("=", spec.options[1].separator.?);
    try testing.expectEqual(@as(usize, 3), spec.subcommands.len);
    const co = spec.subcommands[0];
    try testing.expectEqualStrings("co", co.names[1]);
    try testing.expectEqual(@as(f32, 100), co.args[0].suggestions[0].priority);
    try testing.expectEqual(Native.git_branches, co.args[0].generators[0].native.?);
    try testing.expect(spec.subcommands[1].dangerous);
    try testing.expectEqual(@as(usize, 1), spec.subcommands[1].args.len);
    try testing.expectEqualStrings("git-lfs", spec.subcommands[2].load_spec.?);

    try testing.expectError(error.InvalidSpec, parse(arena.allocator(), "{"));
    try testing.expectError(error.InvalidSpec, parse(arena.allocator(), "{\"description\":\"x\"}"));
}

test "autocomplete spec: native generator detection" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = .{
        .{ "[\"git\",\"--no-optional-locks\",\"branch\",\"-a\",\"--no-color\"]", Native.git_branches },
        .{ "[\"git\",\"remote\"]", Native.git_remotes },
        .{ "[\"git\",\"tag\",\"--list\"]", Native.git_tags },
        .{ "[\"bash\",\"-c\",\"until [[ -f package.json ]] || [[ $PWD = '/' ]]; do cd ..; done; cat package.json\"]", Native.package_scripts },
        .{ "[\"bash\",\"-c\",\"make -qp | awk -F':' '/^[a-zA-Z0-9][^$#\\\\/\\\\t=]*:([^=]|$)/ {print $1}'\"]", Native.make_targets },
    };
    inline for (cases) |c| {
        const v = try json.parseFromSliceLeaky(json.Value, a, c[0], .{});
        try testing.expectEqual(c[1], nativeFor(v).?);
    }
    const none = try json.parseFromSliceLeaky(json.Value, a, "[\"docker\",\"ps\"]", .{});
    try testing.expect(nativeFor(none) == null);
    try testing.expect(nativeFor(.null) == null);
}

test "autocomplete spec: registry aliases and LRU" {
    const testing = std.testing;
    const sources = [_]Source{
        .{ .key = "a", .text = "{\"name\":[\"a\",\"aa\"]}" },
        .{ .key = "b", .text = "{\"name\":[\"b\"]}" },
        .{ .key = "broken", .text = "{" },
    };
    var reg = try Registry.init(testing.allocator, &sources,
        \\{"aliases":{"aa":"a","ghost":"missing"}}
    );
    defer reg.deinit();

    try testing.expectEqualStrings("a", reg.keyForCommand("a").?);
    try testing.expectEqualStrings("a", reg.keyForCommand("aa").?);
    try testing.expect(reg.keyForCommand("ghost") == null);
    try testing.expect(reg.keyForCommand("x/y") == null);

    const a = reg.get("a").?;
    try testing.expectEqualStrings("aa", a.names[1]);
    try testing.expect(reg.get("a").? == a);
    try testing.expect(reg.get("broken") == null);
    try testing.expect(reg.get("broken") == null);
    try testing.expect(reg.get("nope") == null);
    try testing.expectEqual(@as(usize, 2), reg.cachedCount());
}

test "autocomplete spec: LRU evicts the least recently used" {
    const testing = std.testing;
    var srcs: [Registry.capacity + 1]Source = undefined;
    var keybuf: [Registry.capacity + 1][4]u8 = undefined;
    for (&srcs, &keybuf, 0..) |*s, *kb, i| {
        const k = std.fmt.bufPrint(kb, "k{d}", .{i}) catch unreachable;
        s.* = .{ .key = k, .text = "{\"name\":[\"x\"]}" };
    }
    var reg = try Registry.init(testing.allocator, &srcs, "{}");
    defer reg.deinit();
    for (srcs[0..Registry.capacity]) |s| _ = reg.get(s.key).?;
    // Touch k0 so k1 is the oldest, then load one more.
    _ = reg.get("k0").?;
    _ = reg.get(srcs[Registry.capacity].key).?;
    try testing.expectEqual(@as(usize, Registry.capacity), reg.cachedCount());
    var has_k0 = false;
    var has_k1 = false;
    for (reg.entries) |slot| if (slot) |e| {
        if (std.mem.eql(u8, e.key, "k0")) has_k0 = true;
        if (std.mem.eql(u8, e.key, "k1")) has_k1 = true;
    };
    try testing.expect(has_k0);
    try testing.expect(!has_k1);
}

test "autocomplete spec: every embedded spec parses and index matches" {
    const testing = std.testing;
    var reg = try Registry.init(testing.allocator, embedded, embedded_index);
    defer reg.deinit();
    for (embedded) |s| {
        const spec = reg.get(s.key) orelse {
            std.debug.print("spec {s} failed to parse\n", .{s.key});
            return error.TestUnexpectedResult;
        };
        try testing.expect(spec.names.len > 0);
    }

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const idx = try json.parseFromSliceLeaky(json.Value, arena.allocator(), embedded_index, .{});
    try testing.expectEqual(@as(i64, @intCast(embedded.len)), idx.object.get("count").?.integer);
}
