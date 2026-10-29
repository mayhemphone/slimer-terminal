//! Matching and scoring for autocomplete candidates (PLAN 6b): prefix
//! match quality, history frequency, recency, cwd affinity and spec
//! order/priority. Fuzzy matching is only used for subcommands and
//! options, never for paths or history.
const std = @import("std");
const History = @import("History.zig");

pub const Match = struct {
    /// 1.0 exact-case prefix, 0.8 case-insensitive prefix, (0, 0.5] fuzzy.
    quality: f32,
    /// Bytes of the candidate's display that matched as a prefix (for
    /// bolding). 0 for fuzzy matches.
    prefix_len: usize,
};

pub fn prefix(candidate: []const u8, typed: []const u8) ?Match {
    if (typed.len > candidate.len) return null;
    if (std.mem.startsWith(u8, candidate, typed)) return .{ .quality = 1.0, .prefix_len = typed.len };
    if (std.ascii.startsWithIgnoreCase(candidate, typed)) return .{ .quality = 0.8, .prefix_len = typed.len };
    return null;
}

/// Case-insensitive subsequence match. Rewards consecutive runs and
/// matches at word starts (after `-`, `_`, `/`, `.`). Requires the first
/// typed character to match the candidate's first alphanumeric
/// character so `-m` doesn't fuzzy-match everything with an `m`.
pub fn fuzzy(candidate: []const u8, typed: []const u8) ?Match {
    if (typed.len == 0 or typed.len > candidate.len) return null;
    var ci: usize = 0;
    var ti: usize = 0;
    var total: f32 = 0;
    var run: f32 = 0;
    var first = true;
    while (ti < typed.len and ci < candidate.len) : (ci += 1) {
        const c = std.ascii.toLower(candidate[ci]);
        const t = std.ascii.toLower(typed[ti]);
        const word_start = ci == 0 or switch (candidate[ci - 1]) {
            '-', '_', '/', '.', ' ' => true,
            else => false,
        };
        if (c == t) {
            run += 1;
            total += 1 + run + (if (word_start) @as(f32, 2) else 0);
            ti += 1;
            first = false;
        } else {
            if (first and std.ascii.isAlphanumeric(candidate[ci]) and std.ascii.isAlphanumeric(typed[ti])) return null;
            run = 0;
        }
    }
    if (ti < typed.len) return null;
    const max: f32 = @floatFromInt(typed.len * 4 + typed.len * (typed.len + 1) / 2);
    const q = 0.5 * @min(1.0, total / max);
    return .{ .quality = @max(q, 0.05), .prefix_len = 0 };
}

pub const Inputs = struct {
    match: Match,
    /// Fig priority, 0-100, default 50.
    priority: f32 = 50,
    /// Position in the spec (0 first) and the list size.
    order: usize = 0,
    order_len: usize = 1,
    /// Native generator hint (current branch etc.).
    boost: f32 = 0,
    history: ?History.Stat = null,
    now: i64 = 0,
    cwd_hash: u64 = 0,
};

const week_s: f32 = 7 * 24 * 3600;

pub fn score(in: Inputs) f32 {
    var s: f32 = in.match.quality * 100;
    s += (std.math.clamp(in.priority, 0, 100) - 50) * 0.5;
    if (in.order_len > 0) {
        const pos: f32 = @floatFromInt(@min(in.order, in.order_len));
        const len: f32 = @floatFromInt(in.order_len);
        s += 8 * (1 - pos / len);
    }
    s += in.boost * 5;
    if (in.history) |h| {
        const count: f32 = @floatFromInt(h.count);
        s += @min(40, 12 * std.math.log2(1 + count));
        const age: f32 = @floatFromInt(@max(0, in.now - h.last));
        s += 20 * @exp(-age / week_s);
        if (in.cwd_hash != 0 and h.cwd_hash == in.cwd_hash) {
            const cc: f32 = @floatFromInt(h.cwd_count);
            s += @min(25, 10 + 5 * std.math.log2(1 + cc));
        }
    }
    return s;
}

test "autocomplete rank: prefix and fuzzy" {
    const testing = std.testing;
    try testing.expectEqual(@as(f32, 1.0), prefix("status", "sta").?.quality);
    try testing.expectEqual(@as(f32, 0.8), prefix("Status", "sta").?.quality);
    try testing.expect(prefix("st", "sta") == null);
    try testing.expect(prefix("commit", "sta") == null);

    try testing.expect(fuzzy("cherry-pick", "chp") != null);
    try testing.expect(fuzzy("checkout", "cko") != null);
    try testing.expect(fuzzy("status", "xyz") == null);
    // The first character must anchor at the start.
    try testing.expect(fuzzy("commit", "mit") == null);
    try testing.expect(fuzzy("--message", "--msg") != null);
    // Contiguous beats scattered.
    try testing.expect(fuzzy("stash", "sth").?.quality < fuzzy("sthing", "sth").?.quality);
    try testing.expect(fuzzy("status", "stat").?.quality <= 0.5);
}

test "autocomplete rank: history, recency and cwd affinity order" {
    const testing = std.testing;
    const m: Match = .{ .quality = 1.0, .prefix_len = 1 };
    const base = score(.{ .match = m, .order = 3, .order_len = 10 });
    const used = score(.{ .match = m, .order = 3, .order_len = 10, .history = .{ .count = 5, .last = 0 }, .now = 10 * 24 * 3600 });
    const recent = score(.{ .match = m, .order = 3, .order_len = 10, .history = .{ .count = 5, .last = 100 }, .now = 200 });
    const here = score(.{ .match = m, .order = 3, .order_len = 10, .history = .{ .count = 5, .last = 100, .cwd_hash = 7, .cwd_count = 2 }, .now = 200, .cwd_hash = 7 });
    try testing.expect(base < used);
    try testing.expect(used < recent);
    try testing.expect(recent < here);

    // Spec order breaks ties; priority overrides order.
    try testing.expect(score(.{ .match = m, .order = 0, .order_len = 10 }) > score(.{ .match = m, .order = 5, .order_len = 10 }));
    try testing.expect(score(.{ .match = m, .order = 9, .order_len = 10, .priority = 80 }) > score(.{ .match = m, .order = 0, .order_len = 10 }));
    // Exact prefix beats a fuzzy match even with some history.
    try testing.expect(score(.{ .match = m }) > score(.{ .match = fuzzy("checkout", "cko").?, .history = .{ .count = 1, .last = 0 }, .now = 3600 }));
}
