//! The autocomplete suggestion engine (PLAN 6b). Portable: no apprt or
//! macOS APIs. One engine is shared by every surface in the process
//! (specs, history and caches are global); queries run on the caller's
//! thread, which for the embedded apprt is the main thread.
//!
//! A query takes the shell-reported buffer and cursor plus the cwd and
//! returns up to `max_items` ranked suggestions. Sources:
//!
//! - specs: subcommands, options, positional args, option args;
//! - filesystem: `filepaths` / `folders` templates, `cd`, commands with
//!   no spec, and redirection targets;
//! - history: whole-line prefix matches at the first token of the
//!   buffer, plus frequency/recency/cwd stats for every candidate;
//! - native generators: git branches/remotes/tags, package.json
//!   scripts, make targets.
//!
//! Generator `script`s are never executed (the `scripted` tier is future
//! work). Candidate text that would be rejected by the accept path
//! (control characters, bidi overrides, ...) is dropped here.
const Engine = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wire = @import("main.zig");
const Spec = @import("Spec.zig");
const Tokenizer = @import("Tokenizer.zig");
const History = @import("History.zig");
const Fs = @import("Fs.zig");
const Generators = @import("Generators.zig");
const Rank = @import("Rank.zig");

pub const max_items = 8;

/// Sync with `ghostty_autocomplete_kind_e` in ghostty.h.
pub const Kind = enum(u8) {
    subcommand = 0,
    option = 1,
    arg = 2,
    path = 3,
    history = 4,
    generator = 5,
};

pub const Suggestion = struct {
    /// Replacement text. For `history` items it replaces the whole line;
    /// for everything else, the current token.
    text: []const u8,
    display: []const u8,
    description: []const u8,
    kind: Kind,
    dangerous: bool,
    /// Bytes at the start of `display` that matched what was typed.
    match_len: u32,
};

pub const Result = struct {
    items: []const Suggestion = &.{},
    /// The current token: byte range in the buffer and its length in
    /// characters (code points), matching the 6A cursor unit.
    replace_start_byte: usize = 0,
    replace_end_byte: usize = 0,
    replace_start: u32 = 0,
    replace_len: u32 = 0,
};

pub const Options = struct {
    sources: []const Spec.Source = Spec.embedded,
    index: []const u8 = Spec.embedded_index,
    home: []const u8 = "",
};

pub const Query = struct {
    buffer: []const u8,
    /// Character index, as reported by zle `$CURSOR`.
    cursor: u32,
    /// Absolute cwd, or empty if unknown.
    cwd: []const u8 = "",
    /// Monotonic time for cache TTLs.
    now: Io.Timestamp,
    /// Wall clock, unix seconds, for history recency.
    now_unix: i64,
};

alloc: Allocator,
io: Io,
registry: Spec.Registry,
history: History,
fs: Fs,
generators: Generators,
home: []const u8 = "",
scratch: std.heap.ArenaAllocator,

pub fn init(alloc: Allocator, io: Io, opts: Options) Allocator.Error!Engine {
    var registry = try Spec.Registry.init(alloc, opts.sources, opts.index);
    errdefer registry.deinit();
    const home = try alloc.dupe(u8, opts.home);
    return .{
        .alloc = alloc,
        .io = io,
        .registry = registry,
        .history = .init(alloc, io),
        .fs = .init(alloc, io),
        .generators = .init(alloc, io),
        .home = home,
        .scratch = .init(alloc),
    };
}

pub fn deinit(self: *Engine) void {
    self.registry.deinit();
    self.history.deinit();
    self.fs.deinit();
    self.generators.deinit();
    self.alloc.free(self.home);
    self.scratch.deinit();
}

pub fn setHome(self: *Engine, home: []const u8) Allocator.Error!void {
    const copy = try self.alloc.dupe(u8, home);
    self.alloc.free(self.home);
    self.home = copy;
}

/// Record a submitted command line (OSC 133 C).
pub fn record(self: *Engine, line: []const u8, cwd: []const u8, now_unix: i64) void {
    self.history.record(line, cwd, now_unix);
}

/// Words that run the next word as a command.
const precommands = [_][]const u8{
    "sudo", "doas", "noglob", "nocorrect", "command", "builtin", "exec", "nohup", "time", "env", "caffeinate",
};

fn isAssignment(w: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, w, '=') orelse return false;
    if (eq == 0) return false;
    for (w[0..eq], 0..) |c, i| {
        if (!(std.ascii.isAlphabetic(c) or c == '_' or (i > 0 and std.ascii.isDigit(c)))) return false;
    }
    return true;
}

const Cand = struct {
    text: []const u8,
    display: []const u8,
    description: []const u8 = "",
    kind: Kind,
    dangerous: bool = false,
    match_len: usize = 0,
    score: f32,
    /// Command-name candidates: spec key whose description is filled in
    /// only if the candidate makes the final list.
    spec_key: ?[]const u8 = null,
    /// Path candidates that are symlinks: the absolute path, resolved
    /// (one stat) only if the candidate makes the final list.
    link_abs: ?[]const u8 = null,
    /// The link must resolve to a directory (`folders` template).
    link_needs_dir: bool = false,
};

const Ctx = struct {
    engine: *Engine,
    a: Allocator,
    q: Query,
    cwd_hash: u64,
    /// Basename of the command being completed, for history word stats.
    command: []const u8 = "",
    /// The current token's unquoted value.
    current: []const u8 = "",
    cands: std.ArrayList(Cand) = .empty,
    by_text: std.StringHashMapUnmanaged(usize) = .empty,

    fn add(self: *Ctx, c: Cand) void {
        if (c.text.len == 0 or !wire.isSafeAcceptText(c.text)) return;
        // A suggestion that wouldn't change the token is noise.
        if (c.kind != .history and std.mem.eql(u8, c.text, self.current)) return;
        const gop = self.by_text.getOrPut(self.a, c.text) catch return;
        if (gop.found_existing) {
            const prev = &self.cands.items[gop.value_ptr.*];
            if (c.score > prev.score) prev.* = c;
            return;
        }
        gop.value_ptr.* = self.cands.items.len;
        self.cands.append(self.a, c) catch {
            _ = self.by_text.remove(c.text);
        };
    }

    fn stat(self: *const Ctx, word: []const u8) ?History.Stat {
        return self.engine.history.tokenStat(self.command, word);
    }

    fn rank(self: *const Ctx, in: Rank.Inputs) f32 {
        var i = in;
        i.now = self.q.now_unix;
        i.cwd_hash = self.cwd_hash;
        return Rank.score(i);
    }

    fn concat(self: *const Ctx, parts: []const []const u8) []const u8 {
        return std.mem.concat(self.a, u8, parts) catch "";
    }
};

/// Run a query. The result points into engine-owned scratch memory that
/// is valid until the next query.
pub fn query(self: *Engine, q: Query) Allocator.Error!Result {
    _ = self.scratch.reset(.retain_capacity);
    const a = self.scratch.allocator();
    self.history.ensureLoaded();

    const tok = try Tokenizer.tokenize(a, q.buffer, q.cursor);
    var result: Result = .{
        .replace_start_byte = tok.current.start,
        .replace_end_byte = tok.cursor_byte,
        .replace_start = @intCast(Tokenizer.charCount(q.buffer[0..tok.current.start])),
        .replace_len = @intCast(Tokenizer.charCount(q.buffer[tok.current.start..tok.cursor_byte])),
    };
    if (tok.@"opaque" or q.buffer.len == 0) return result;

    var ctx: Ctx = .{
        .engine = self,
        .a = a,
        .q = q,
        .cwd_hash = History.cwdHash(q.cwd),
        .current = tok.current.value,
    };
    const typed = tok.current.value;

    if (tok.redirect) {
        self.addPaths(&ctx, typed, false, "");
    } else {
        // Skip env assignments and precommand modifiers.
        var words = tok.words;
        var skipped = false;
        while (words.len > 0) {
            const w = words[0].value;
            if (isAssignment(w)) {
                words = words[1..];
                skipped = true;
                continue;
            }
            var is_pre = false;
            for (precommands) |p| if (std.mem.eql(u8, w, p)) {
                is_pre = true;
            };
            if (!is_pre) break;
            words = words[1..];
            skipped = true;
            // Options of the precommand (`sudo -u root`) are skipped
            // too; option arguments are not understood.
            while (words.len > 0 and words[0].value.len > 1 and words[0].value[0] == '-') words = words[1..];
        }

        if (words.len == 0) {
            const whole_line = !skipped and tok.first_command and
                tok.cursor_byte == q.buffer.len and tok.open_quote == 0;
            self.addCommands(&ctx, typed, if (whole_line) q.buffer[0..tok.cursor_byte] else null);
        } else {
            try self.completeCommand(&ctx, words, typed);
        }
    }

    // Rank and take the top items.
    const cands = ctx.cands.items;
    std.mem.sort(Cand, cands, {}, struct {
        fn lt(_: void, x: Cand, y: Cand) bool {
            if (x.score != y.score) return x.score > y.score;
            if (x.display.len != y.display.len) return x.display.len < y.display.len;
            return std.mem.lessThan(u8, x.display, y.display);
        }
    }.lt);
    var list: std.ArrayList(Suggestion) = try .initCapacity(a, max_items);
    for (cands) |cand| {
        if (list.items.len == max_items) break;
        var c = cand;
        if (c.link_abs) |abs| {
            if (Fs.isDir(self.io, abs)) {
                c.text = ctx.concat(&.{ c.text, "/" });
                c.display = ctx.concat(&.{ c.display, "/" });
                if (std.mem.eql(u8, c.text, ctx.current)) continue;
            } else if (c.link_needs_dir) continue;
        }
        const dst = list.addOneAssumeCapacity();
        var desc = c.description;
        if (c.spec_key) |k| if (self.registry.get(k)) |spec| {
            desc = spec.description;
        };
        dst.* = .{
            .text = c.text,
            .display = c.display,
            .description = desc,
            .kind = c.kind,
            .dangerous = c.dangerous,
            .match_len = @intCast(@min(c.match_len, c.display.len)),
        };
    }
    result.items = list.items;
    return result;
}

/// Command position: spec names, commands seen in history, and (when
/// the cursor ends the first token of the buffer) whole history lines.
fn addCommands(self: *Engine, ctx: *Ctx, typed: []const u8, whole_line_prefix: ?[]const u8) void {
    if (typed.len == 0) return;
    if (std.mem.indexOfScalar(u8, typed, '/') != null) {
        self.addPaths(ctx, typed, false, "");
        return;
    }

    for (self.registry.sources, 0..) |src, i| {
        if (std.mem.indexOfScalar(u8, src.key, '/') != null) continue;
        const m = Rank.prefix(src.key, typed) orelse continue;
        ctx.add(.{
            .text = src.key,
            .display = src.key,
            .kind = .subcommand,
            .match_len = m.prefix_len,
            .spec_key = src.key,
            .score = ctx.rank(.{
                .match = m,
                .order = i,
                .order_len = self.registry.sources.len,
                .history = self.history.tokenStat("", src.key),
            }) - 10,
        });
    }
    var alias_it = self.registry.aliases.iterator();
    while (alias_it.next()) |kv| {
        const m = Rank.prefix(kv.key_ptr.*, typed) orelse continue;
        ctx.add(.{
            .text = kv.key_ptr.*,
            .display = kv.key_ptr.*,
            .kind = .subcommand,
            .match_len = m.prefix_len,
            .spec_key = kv.value_ptr.*,
            .score = ctx.rank(.{ .match = m, .history = self.history.tokenStat("", kv.key_ptr.*) }) - 12,
        });
    }

    var it = self.history.lineIterator();
    while (it.next()) |kv| {
        const line = kv.key_ptr.*;
        // First word of the line as a command name.
        const first_end = std.mem.indexOfAny(u8, line, " \t;|&") orelse line.len;
        const first = line[0..first_end];
        if (first.len > 0 and !isAssignment(first) and std.mem.indexOfScalar(u8, first, '/') == null) {
            if (Rank.prefix(first, typed)) |m| ctx.add(.{
                .text = first,
                .display = first,
                .kind = .subcommand,
                .match_len = m.prefix_len,
                .spec_key = if (self.registry.keyForCommand(first)) |k| k else null,
                .score = ctx.rank(.{ .match = m, .history = self.history.tokenStat("", first) }) - 10,
            });
        }

        if (whole_line_prefix) |p| {
            if (line.len > p.len and std.mem.startsWith(u8, line, p) and
                std.mem.indexOfScalar(u8, line, '\n') == null)
            {
                ctx.add(.{
                    .text = line,
                    .display = line,
                    .kind = .history,
                    .match_len = p.len,
                    .score = ctx.rank(.{
                        .match = .{ .quality = 1.0, .prefix_len = p.len },
                        .history = kv.value_ptr.*,
                    }) - 5,
                });
            }
        }
    }
}

/// The spec node to use for `node`: its `loadSpec` target when the node
/// itself is empty.
fn effective(self: *Engine, node: *const Spec.Subcommand) *const Spec.Subcommand {
    const ls = node.load_spec orelse return node;
    if (node.subcommands.len > 0 or node.options.len > 0 or node.args.len > 0) return node;
    return self.registry.get(ls) orelse node;
}

const Walk = struct {
    node: *const Spec.Subcommand,
    persistent: std.ArrayList(*const Spec.Option) = .empty,
    used: std.ArrayList([]const u8) = .empty,
    pending: ?struct { opt: *const Spec.Option, idx: usize } = null,
    arg_idx: usize = 0,
    options_ended: bool = false,

    fn findOption(self: *const Walk, name: []const u8) ?*const Spec.Option {
        for (self.node.options) |*o| for (o.names) |n| if (std.mem.eql(u8, n, name)) return o;
        for (self.persistent.items) |o| for (o.names) |n| if (std.mem.eql(u8, n, name)) return o;
        return null;
    }

    fn currentArg(self: *const Walk) ?*const Spec.Arg {
        const args = self.node.args;
        if (args.len == 0) return null;
        if (self.arg_idx < args.len) return &args[self.arg_idx];
        const last = &args[args.len - 1];
        return if (last.variadic) last else null;
    }
};

fn completeCommand(self: *Engine, ctx: *Ctx, words: []const Tokenizer.Word, typed: []const u8) Allocator.Error!void {
    const cmd = std.fs.path.basename(words[0].value);
    ctx.command = cmd;
    const key = self.registry.keyForCommand(cmd) orelse {
        // No spec: directories for cd, files for everything else.
        self.addPaths(ctx, typed, std.mem.eql(u8, cmd, "cd") or std.mem.eql(u8, cmd, "pushd"), "");
        return;
    };
    const root = self.registry.get(key) orelse {
        self.addPaths(ctx, typed, false, "");
        return;
    };

    var w: Walk = .{ .node = self.effective(root) };
    for (w.node.options) |*o| if (o.persistent) try w.persistent.append(ctx.a, o);

    var i: usize = 1;
    while (i < words.len) : (i += 1) {
        const word = words[i].value;
        if (w.pending) |p| {
            const next = p.idx + 1;
            w.pending = if (next < p.opt.args.len and !p.opt.args[next].optional)
                .{ .opt = p.opt, .idx = next }
            else
                null;
            continue;
        }
        if (!w.options_ended and std.mem.eql(u8, word, "--")) {
            w.options_ended = true;
            continue;
        }
        if (!w.options_ended and word.len > 1 and word[0] == '-') {
            try self.consumeOption(ctx, &w, word);
            continue;
        }
        if (w.arg_idx == 0 and !w.options_ended) {
            if (findSub(w.node, word)) |sub| {
                w.node = self.effective(sub);
                w.arg_idx = 0;
                for (w.node.options) |*o| if (o.persistent) try w.persistent.append(ctx.a, o);
                continue;
            }
        }
        if (w.currentArg()) |arg| {
            if (arg.is_command) {
                // The rest is a new command (`sudo`, `npm exec`, ...).
                return self.completeCommand(ctx, words[i..], typed);
            }
        }
        w.arg_idx += 1;
    }

    // The current token.
    if (w.pending) |p| {
        self.addArg(ctx, &p.opt.args[p.idx], typed, "");
        return;
    }

    if (!w.options_ended and typed.len > 0 and typed[0] == '-') {
        // `--opt=value`: complete the value.
        if (std.mem.indexOfScalar(u8, typed, '=')) |eq| {
            if (w.findOption(typed[0..eq])) |opt| if (opt.args.len > 0) {
                self.addArg(ctx, &opt.args[0], typed[eq + 1 ..], typed[0 .. eq + 1]);
            };
            return;
        }
        self.addOptions(ctx, &w, typed);
        return;
    }

    if (w.currentArg()) |arg| if (arg.is_command) {
        self.addCommands(ctx, typed, null);
        return;
    };

    if (w.arg_idx == 0 and !w.options_ended) self.addSubcommands(ctx, w.node, typed);
    if (w.node.requires_subcommand and w.arg_idx == 0) return;
    if (w.currentArg()) |arg| self.addArg(ctx, arg, typed, "");
}

fn findSub(node: *const Spec.Subcommand, word: []const u8) ?*const Spec.Subcommand {
    for (node.subcommands) |*s| for (s.names) |n| if (std.mem.eql(u8, n, word)) return s;
    return null;
}

fn consumeOption(self: *Engine, ctx: *Ctx, w: *Walk, word: []const u8) Allocator.Error!void {
    _ = self;
    if (w.findOption(word)) |opt| {
        try w.used.append(ctx.a, opt.names[0]);
        if (opt.args.len > 0 and !opt.args[0].optional) w.pending = .{ .opt = opt, .idx = 0 };
        return;
    }
    // `--name=value` or `--name<sep>value`.
    if (std.mem.indexOfScalar(u8, word, '=')) |eq| {
        if (w.findOption(word[0..eq])) |opt| try w.used.append(ctx.a, opt.names[0]);
        return;
    }
    // Combined short flags (`-am`), the last may take an argument, or a
    // short option with its value attached (`-mmsg`).
    if (word.len > 2 and word[1] != '-') {
        var j: usize = 1;
        while (j < word.len) : (j += 1) {
            const flag = [2]u8{ '-', word[j] };
            const opt = w.findOption(&flag) orelse return;
            try w.used.append(ctx.a, opt.names[0]);
            if (opt.args.len > 0) {
                if (j == word.len - 1 and !opt.args[0].optional) w.pending = .{ .opt = opt, .idx = 0 };
                return;
            }
        }
    }
}

fn addSubcommands(self: *Engine, ctx: *Ctx, node: *const Spec.Subcommand, typed: []const u8) void {
    _ = self;
    for (node.subcommands, 0..) |*s, i| {
        if (s.hidden) continue;
        var best: ?Rank.Match = null;
        var best_name: []const u8 = s.names[0];
        for (s.names) |n| {
            const m = Rank.prefix(n, typed) orelse (if (typed.len >= 2) Rank.fuzzy(n, typed) else null) orelse continue;
            if (best == null or m.quality > best.?.quality) {
                best = m;
                best_name = n;
            }
        }
        const m = best orelse continue;
        ctx.add(.{
            .text = best_name,
            .display = best_name,
            .description = s.description,
            .kind = .subcommand,
            .dangerous = s.dangerous,
            .match_len = m.prefix_len,
            .score = ctx.rank(.{
                .match = m,
                .priority = s.priority,
                .order = i,
                .order_len = node.subcommands.len,
                .history = ctx.stat(best_name),
            }),
        });
    }
}

fn addOptions(self: *Engine, ctx: *Ctx, w: *const Walk, typed: []const u8) void {
    _ = self;
    const total = w.node.options.len + w.persistent.items.len;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const opt: *const Spec.Option = if (i < w.node.options.len)
            &w.node.options[i]
        else
            w.persistent.items[i - w.node.options.len];
        if (opt.hidden) continue;
        if (i >= w.node.options.len and opt.persistent and isOwnOption(w.node, opt)) continue;
        if (!opt.repeatable and wasUsed(w, opt)) continue;
        if (excluded(w, opt)) continue;

        var best: ?Rank.Match = null;
        var best_name: []const u8 = opt.names[0];
        for (opt.names) |n| {
            const m = Rank.prefix(n, typed) orelse (if (typed.len >= 3) Rank.fuzzy(n, typed) else null) orelse continue;
            if (best == null or m.quality > best.?.quality) {
                best = m;
                best_name = n;
            }
        }
        const m = best orelse continue;
        const sep: []const u8 = if (opt.args.len > 0) (opt.separator orelse "") else "";
        const text = if (sep.len > 0) ctx.concat(&.{ best_name, sep }) else best_name;
        const display = if (opt.args.len > 0 and opt.args[0].name.len > 0)
            ctx.concat(&.{ best_name, if (sep.len > 0) sep else " ", "<", opt.args[0].name, ">" })
        else
            best_name;
        ctx.add(.{
            .text = text,
            .display = display,
            .description = opt.description,
            .kind = .option,
            .dangerous = opt.dangerous,
            .match_len = m.prefix_len,
            .score = ctx.rank(.{
                .match = m,
                .priority = opt.priority,
                .order = i,
                .order_len = total,
                .history = ctx.stat(best_name),
            }),
        });
    }
}

fn isOwnOption(node: *const Spec.Subcommand, opt: *const Spec.Option) bool {
    for (node.options) |*o| if (o == opt) return true;
    return false;
}

fn wasUsed(w: *const Walk, opt: *const Spec.Option) bool {
    for (w.used.items) |u| if (std.mem.eql(u8, u, opt.names[0])) return true;
    return false;
}

fn excluded(w: *const Walk, opt: *const Spec.Option) bool {
    for (opt.exclusive_on) |ex| for (w.used.items) |u| {
        if (std.mem.eql(u8, u, ex)) return true;
        if (w.findOption(ex)) |o| if (std.mem.eql(u8, o.names[0], u)) return true;
    };
    return false;
}

/// Suggestions for one positional or option argument. `prefix_text` is
/// prepended to every inserted text (for `--opt=value`).
fn addArg(self: *Engine, ctx: *Ctx, arg: *const Spec.Arg, typed: []const u8, prefix_text: []const u8) void {
    for (arg.suggestions, 0..) |*s, i| {
        if (s.hidden) continue;
        for (s.names) |n| {
            const m = Rank.prefix(n, typed) orelse continue;
            ctx.add(.{
                .text = if (prefix_text.len > 0) ctx.concat(&.{ prefix_text, n }) else n,
                .display = n,
                .description = s.description,
                .kind = .arg,
                .dangerous = s.dangerous or arg.dangerous,
                .match_len = m.prefix_len,
                .score = ctx.rank(.{
                    .match = m,
                    .priority = s.priority,
                    .order = i,
                    .order_len = arg.suggestions.len,
                    .history = ctx.stat(n),
                }),
            });
            break;
        }
    }

    var templates = arg.templates;
    for (arg.generators) |g| {
        templates.filepaths = templates.filepaths or g.templates.filepaths;
        templates.folders = templates.folders or g.templates.folders;
        const kind = g.native orelse continue;
        if (ctx.q.cwd.len == 0) continue;
        const items = self.generators.get(kind, ctx.q.cwd, ctx.q.now);
        for (items, 0..) |it, i| {
            const m = Rank.prefix(it.name, typed) orelse continue;
            ctx.add(.{
                .text = if (prefix_text.len > 0) ctx.concat(&.{ prefix_text, it.name }) else it.name,
                .display = it.name,
                .description = it.description,
                .kind = .generator,
                .dangerous = arg.dangerous,
                .match_len = m.prefix_len,
                .score = ctx.rank(.{
                    .match = m,
                    .order = i,
                    .order_len = items.len,
                    .boost = it.boost,
                    .history = ctx.stat(it.name),
                }),
            });
        }
    }

    if (templates.filepaths) {
        self.addPaths(ctx, typed, false, prefix_text);
    } else if (templates.folders) {
        self.addPaths(ctx, typed, true, prefix_text);
    }
}

fn addPaths(self: *Engine, ctx: *Ctx, typed: []const u8, folders_only: bool, prefix_text: []const u8) void {
    const sp = Fs.split(typed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = Fs.resolveDir(&buf, ctx.q.cwd, self.home, sp.dir_text) orelse return;
    const listing = self.fs.list(abs, ctx.q.now) orelse return;
    const show_hidden = sp.base.len > 0 and sp.base[0] == '.';
    for (listing.entries) |e| {
        if (e.name.len > 0 and e.name[0] == '.' and !show_hidden) continue;
        if (folders_only and e.kind == .file) continue;
        const m = Rank.prefix(e.name, sp.base) orelse continue;
        const is_dir = e.kind == .dir;
        const slash: []const u8 = if (is_dir) "/" else "";
        const text = ctx.concat(&.{ prefix_text, sp.dir_text, e.name, slash });
        ctx.add(.{
            .text = text,
            .display = ctx.concat(&.{ e.name, slash }),
            .kind = .path,
            .match_len = m.prefix_len,
            .link_abs = if (e.kind == .link) ctx.concat(&.{ abs, "/", e.name }) else null,
            .link_needs_dir = folders_only,
            .score = ctx.rank(.{
                .match = m,
                // Directories slightly ahead; shorter names next.
                .boost = if (is_dir) 0.4 else 0,
                .history = ctx.stat(text[prefix_text.len..]),
            }),
        });
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const test_sources = [_]Spec.Source{
    .{ .key = "git", .text =
    \\{"name":["git"],"description":"VCS","options":[{"name":["-C"],"args":[{"name":"path","template":["folders"]}]},{"name":["--version"]}],
    \\"subcommands":[
    \\ {"name":["status"],"description":"Show status","options":[{"name":["-s","--short"]},{"name":["-u","--untracked-files"],"requiresSeparator":true,"args":[{"name":"mode","isOptional":true,"suggestions":[{"name":["no"]},{"name":["all"]}]}]}]},
    \\ {"name":["stash"],"subcommands":[{"name":["pop"]},{"name":["drop"],"isDangerous":true}]},
    \\ {"name":["switch"],"options":[{"name":["-c","--create"],"args":[{"name":"new-branch"}]}],"args":[{"name":"branch","generators":[{"script":["git","branch","--no-color"],"hasPostProcess":true,"hasCustom":false}]}]},
    \\ {"name":["commit"],"options":[{"name":["-m","--message"],"args":[{"name":"message"}]},{"name":["-a","--all"]},{"name":["--amend"]},{"name":["--fixup"],"requiresSeparator":true,"args":[{"name":"commit","suggestions":[{"name":["HEAD"]}]}]}],"args":[{"name":"pathspec","isOptional":true,"isVariadic":true,"template":["filepaths"]}]},
    \\ {"name":["push"],"options":[{"name":["-f","--force"],"isDangerous":true},{"name":["--force-with-lease"]}]},
    \\ {"name":["secret"],"hidden":true}
    \\]}
    },
    .{ .key = "npm", .text =
    \\{"name":["npm"],"subcommands":[{"name":["run","run-script"],"args":[{"name":"script","generators":[{"script":["bash","-c","cat package.json"],"hasPostProcess":true,"hasCustom":false}]}]},{"name":["install","i"]}]}
    },
    .{ .key = "make", .text =
    \\{"name":["make"],"options":[{"name":["-C"],"args":[{"name":"dir","template":["folders"]}]}],"args":[{"name":"target","isOptional":true,"isVariadic":true,"generators":[{"script":["bash","-c","make -qp"],"hasPostProcess":true,"hasCustom":false}]}]}
    },
    .{ .key = "cd", .text =
    \\{"name":["cd"],"args":[{"name":"dir","template":["folders"]}]}
    },
    .{ .key = "sudo", .text =
    \\{"name":["sudo"],"args":[{"name":"command","isCommand":true}]}
    },
};

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    engine: Engine,
    paths: std.heap.ArenaAllocator,

    fn init(self: *TestEnv) !void {
        self.tmp = testing.tmpDir(.{});
        const n = try self.tmp.dir.realPath(testing.io, &self.root_buf);
        self.root = self.root_buf[0..n];
        self.engine = try Engine.init(testing.allocator, testing.io, .{
            .sources = &test_sources,
            .index = "{\"aliases\":{}}",
            .home = self.root,
        });
        self.engine.history.loaded = true;
        self.paths = .init(testing.allocator);
    }

    fn deinit(self: *TestEnv) void {
        self.engine.deinit();
        self.paths.deinit();
        self.tmp.cleanup();
    }

    fn path(self: *TestEnv, sub: []const u8) ![]const u8 {
        return std.fs.path.join(self.paths.allocator(), &.{ self.root, sub });
    }

    fn q(self: *TestEnv, buffer: []const u8, cwd: []const u8) !Result {
        return self.engine.query(.{
            .buffer = buffer,
            .cursor = @intCast(Tokenizer.charCount(buffer)),
            .cwd = cwd,
            .now = .{ .nanoseconds = 0 },
            .now_unix = 1_000_000,
        });
    }
};

fn texts(r: Result) ![]const []const u8 {
    const out = try testing.allocator.alloc([]const u8, r.items.len);
    for (r.items, out) |it, *o| o.* = it.text;
    return out;
}

fn expectFirst(r: Result, text: []const u8) !void {
    if (r.items.len == 0 or !std.mem.eql(u8, r.items[0].text, text)) {
        std.debug.print("expected first {s}, got:\n", .{text});
        for (r.items) |it| std.debug.print("  {s}\n", .{it.text});
        return error.TestUnexpectedResult;
    }
}

fn has(r: Result, text: []const u8) bool {
    for (r.items) |it| if (std.mem.eql(u8, it.text, text)) return true;
    return false;
}

fn find(r: Result, text: []const u8) ?Suggestion {
    for (r.items) |it| if (std.mem.eql(u8, it.text, text)) return it;
    return null;
}

test "autocomplete engine: spec walk subcommands and options" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    var r = try env.q("git st", "");
    try expectFirst(r, "status");
    try testing.expectEqual(Kind.subcommand, r.items[0].kind);
    try testing.expectEqualStrings("Show status", r.items[0].description);
    try testing.expectEqual(@as(u32, 2), r.items[0].match_len);
    try testing.expectEqual(@as(u32, 4), r.replace_start);
    try testing.expectEqual(@as(u32, 2), r.replace_len);
    // Fuzzy subcommand: "st" also fuzzy-matches "stash" and "switch"
    // only by prefix rules; exact prefixes rank above.
    try testing.expect(has(r, "stash"));
    try testing.expect(!has(r, "secret"));

    r = try env.q("git status -", "");
    try testing.expect(has(r, "-s"));
    try testing.expect(has(r, "-u="));
    r = try env.q("git status --sh", "");
    try expectFirst(r, "--short");
    try testing.expectEqual(Kind.option, r.items[0].kind);

    // Used non-repeatable options are not offered again.
    r = try env.q("git status --short --sh", "");
    try testing.expect(!has(r, "--short"));

    // Nested subcommands and dangerous flags.
    r = try env.q("git stash ", "");
    try testing.expect(has(r, "pop"));
    try testing.expect(find(r, "drop").?.dangerous);
    r = try env.q("git push --f", "");
    try testing.expect(find(r, "--force").?.dangerous);
    try testing.expect(!find(r, "--force-with-lease").?.dangerous);

    // Fuzzy only for subcommands/options.
    r = try env.q("git swch", "");
    try expectFirst(r, "switch");

    // Empty buffer: nothing.
    r = try env.q("", "");
    try testing.expectEqual(@as(usize, 0), r.items.len);
    // Unknown spec words don't crash; cursor in a substitution is opaque.
    r = try env.q("echo $(git st", "");
    try testing.expectEqual(@as(usize, 0), r.items.len);
}

test "autocomplete engine: option arguments" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    // `-m` takes a free-text message: no suggestions for it, and the
    // word after it is consumed.
    var r = try env.q("git commit -m ", "");
    try testing.expectEqual(@as(usize, 0), r.items.len);
    r = try env.q("git commit -m msg --am", "");
    try expectFirst(r, "--amend");
    // Combined short flags: -am consumes the message arg.
    r = try env.q("git commit -am msg --am", "");
    try expectFirst(r, "--amend");
    try testing.expect(!has(r, "--all"));

    // requiresSeparator options complete their value after `=`.
    r = try env.q("git status --untracked-files=a", "");
    try expectFirst(r, "--untracked-files=all");
    try testing.expectEqualStrings("all", r.items[0].display);
    r = try env.q("git commit --fixup=H", "");
    try expectFirst(r, "--fixup=HEAD");

    // Root options with folder args.
    try env.tmp.dir.createDirPath(testing.io, "proj/src");
    const cwd = try env.path("proj");
    r = try env.q("git -C s", cwd);
    try expectFirst(r, "src/");
    try testing.expectEqual(Kind.path, r.items[0].kind);
}

test "autocomplete engine: path completion" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const io = testing.io;
    const d = env.tmp.dir;
    try d.createDirPath(io, "w/src/autocomplete");
    try d.createDirPath(io, "w/.hidden");
    try d.createDirPath(io, "w/Docs");
    try d.createDirPath(io, "w/my dir");
    try d.writeFile(io, .{ .sub_path = "w/README.md", .data = "" });
    try d.writeFile(io, .{ .sub_path = "w/.env", .data = "" });
    try d.writeFile(io, .{ .sub_path = "w/src/main.zig", .data = "" });
    try d.writeFile(io, .{ .sub_path = "w/bad\x1bname", .data = "" });
    try d.symLink(io, "src", "w/srclink", .{ .is_directory = true });
    try d.symLink(io, "README.md", "w/readlink", .{});
    const cwd = try env.path("w");

    // No spec: files and dirs, no dotfiles.
    var r = try env.q("vim ", cwd);
    try testing.expect(has(r, "README.md"));
    try testing.expect(has(r, "src/"));
    try testing.expect(!has(r, ".env"));
    try testing.expect(!has(r, "bad\x1bname"));
    // Dotfiles when the partial starts with a dot.
    r = try env.q("vim .", cwd);
    try testing.expect(has(r, ".env"));
    try testing.expect(has(r, ".hidden/"));
    // Nested partial keeps the typed directory.
    r = try env.q("vim src/ma", cwd);
    try expectFirst(r, "src/main.zig");
    try testing.expectEqualStrings("main.zig", r.items[0].display);
    try testing.expectEqual(@as(u32, 2), r.items[0].match_len);
    // Case-insensitive fallback.
    r = try env.q("vim doc", cwd);
    try expectFirst(r, "Docs/");
    // cd lists only folders (spec template), and without a spec too.
    r = try env.q("cd ", cwd);
    try testing.expect(has(r, "src/"));
    try testing.expect(!has(r, "README.md"));
    r = try env.q("pushd ", cwd);
    try testing.expect(!has(r, "README.md"));
    // Home expansion.
    r = try env.q("cd ~/w/s", cwd);
    try expectFirst(r, "~/w/src/");
    // Redirection targets are files.
    r = try env.q("git status > REA", cwd);
    try expectFirst(r, "README.md");
    // Symlinks resolve only for shown items: to a dir gets a slash, to a
    // file doesn't, and a file link is dropped where folders are needed.
    r = try env.q("vim srcl", cwd);
    try expectFirst(r, "srclink/");
    r = try env.q("vim readl", cwd);
    try expectFirst(r, "readlink");
    r = try env.q("cd readl", cwd);
    try testing.expectEqual(@as(usize, 0), r.items.len);
    // A suggestion equal to the token is dropped.
    r = try env.q("vim README.md", cwd);
    try testing.expect(!has(r, "README.md"));
    r = try env.q("git status", cwd);
    try testing.expect(!has(r, "status"));
    // Quoted partial with a space.
    r = try env.q("cd \"my d", cwd);
    try expectFirst(r, "my dir/");
    try testing.expectEqual(@as(u32, 3), r.replace_start);
    try testing.expectEqual(@as(u32, 5), r.replace_len);
}

test "autocomplete engine: native generators" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const io = testing.io;
    const d = env.tmp.dir;
    try d.createDirPath(io, "repo/.git/refs/heads");
    try d.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try d.writeFile(io, .{ .sub_path = "repo/.git/refs/heads/main", .data = "x\n" });
    try d.writeFile(io, .{ .sub_path = "repo/.git/refs/heads/feature", .data = "x\n" });
    try d.writeFile(io, .{ .sub_path = "repo/.git/packed-refs", .data = "x refs/heads/fix-1\n" });
    try d.writeFile(io, .{ .sub_path = "repo/package.json", .data = "{\"scripts\":{\"dev\":\"vite\",\"deploy\":\"x\"}}" });
    try d.writeFile(io, .{ .sub_path = "repo/Makefile", .data = "build:\ntest: build\n" });
    const cwd = try env.path("repo");

    var r = try env.q("git switch f", cwd);
    try testing.expect(has(r, "feature"));
    try testing.expect(has(r, "fix-1"));
    try testing.expectEqual(Kind.generator, find(r, "feature").?.kind);
    // The current branch ranks first with an empty token.
    r = try env.q("git switch ", cwd);
    try expectFirst(r, "main");
    try testing.expectEqualStrings("Current branch", r.items[0].description);
    // An option with a free-text arg suppresses the generator.
    r = try env.q("git switch -c ", cwd);
    try testing.expectEqual(@as(usize, 0), r.items.len);

    r = try env.q("npm run d", cwd);
    try testing.expect(has(r, "dev"));
    try testing.expect(has(r, "deploy"));
    try testing.expectEqualStrings("vite", find(r, "dev").?.description);
    r = try env.q("npm run-script de", cwd);
    try testing.expect(has(r, "deploy"));

    r = try env.q("make t", cwd);
    try expectFirst(r, "test");
    // precommands: sudo is skipped, and a spec with isCommand recurses.
    r = try env.q("sudo make b", cwd);
    try expectFirst(r, "build");
    r = try env.q("FOO=1 make b", cwd);
    try expectFirst(r, "build");
}

test "autocomplete engine: history lines and ranking" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    const e = &env.engine;
    e.record("git stash pop", "/a", 999_000);
    e.record("git stash pop", "/a", 999_100);
    e.record("git status", "/b", 990_000);
    e.record("gitk --all", "/b", 999_000);
    e.record(" git secret", "/a", 999_000);
    e.record("echo multi\nline", "/a", 999_000);

    // First token: commands plus whole history lines.
    var r = try env.q("gi", "/a");
    try testing.expect(has(r, "git"));
    try testing.expect(has(r, "gitk"));
    try testing.expect(has(r, "git stash pop"));
    try testing.expectEqual(Kind.history, find(r, "git stash pop").?.kind);
    try testing.expectEqual(@as(u32, 2), find(r, "git stash pop").?.match_len);
    try testing.expect(!has(r, " git secret"));

    // History lines need the cursor at the end of the first command.
    r = try env.q("ls; gi", "/a");
    try testing.expect(!has(r, "git stash pop"));
    try testing.expect(has(r, "git"));

    // Frequency, recency and cwd: stash outranks status for "st" in /a.
    r = try env.q("git st", "/a");
    try expectFirst(r, "stash");
    // ...but plain spec order wins for a fresh engine with no history.
    var fresh: TestEnv = undefined;
    try fresh.init();
    defer fresh.deinit();
    r = try fresh.q("git st", "/a");
    try expectFirst(r, "status");

    // Multi-line history entries are never offered as a line.
    r = try env.q("ec", "/a");
    for (r.items) |it| try testing.expect(std.mem.indexOfScalar(u8, it.text, '\n') == null);
}

test "autocomplete engine: query latency with warm caches" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();
    // Use the real embedded specs for a realistic walk.
    env.engine.registry.deinit();
    env.engine.registry = try Spec.Registry.init(testing.allocator, Spec.embedded, Spec.embedded_index);

    const io = testing.io;
    const d = env.tmp.dir;
    try d.createDirPath(io, "repo/.git/refs/heads");
    try d.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/main\n" });
    var i: usize = 0;
    var buf: [64]u8 = undefined;
    while (i < 200) : (i += 1) {
        try d.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "repo/.git/refs/heads/b{d}", .{i}), .data = "x\n" });
        try d.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "repo/file{d}.txt", .{i}), .data = "" });
    }
    i = 0;
    while (i < 2000) : (i += 1) {
        env.engine.record(try std.fmt.bufPrint(&buf, "git commit -m change{d}", .{i}), "/x", @intCast(i));
    }
    const cwd = try std.fmt.allocPrint(testing.allocator, "{s}/repo", .{env.root});
    defer testing.allocator.free(cwd);

    const lines = [_][]const u8{ "git st", "git switch b1", "git commit -", "ls fi", "docker compose u", "gi", "kubectl get po", "npm run " };
    const iterations = 1000;
    const start: Io.Timestamp = .now(io, .awake);
    i = 0;
    while (i < iterations) : (i += 1) {
        const line = lines[i % lines.len];
        _ = try env.engine.query(.{
            .buffer = line,
            .cursor = @intCast(line.len),
            .cwd = cwd,
            .now = .{ .nanoseconds = 0 },
            .now_unix = 3000,
        });
    }
    const elapsed = start.durationTo(.now(io, .awake));
    const per_query_us = @divTrunc(elapsed.nanoseconds, iterations * std.time.ns_per_us);
    // Printed only in release runs (`zig test -OReleaseFast ... --test-filter latency`);
    // the build runner treats test stderr as a failure.
    if (@import("builtin").mode != .debug) std.debug.print("autocomplete bench: {d} queries, {d} us/query\n", .{ iterations, per_query_us });
    // Wall-clock bounds are flaky on a loaded machine (parallel builds), so
    // this only catches pathological regressions. Real numbers: run in
    // ReleaseFast; see docs/slimer/AUTOCOMPLETE.md.
    try testing.expect(elapsed.nanoseconds < 30 * std.time.ns_per_s);
}
