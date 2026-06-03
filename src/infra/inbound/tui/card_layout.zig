const std = @import("std");
const d = @import("domain");
const glyphs_mod = @import("glyphs.zig");

/// If `text` (UTF-8 byte count) exceeds `max`, truncate to a length that leaves room for a
/// trailing `…` (caller appends it). Returns `text` if it fits or `max < 3`.
/// Returns a slice at most `max - 3` bytes when truncating.
pub fn truncateWithEllipsis(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    if (max < 3) return text[0..max];
    var i: usize = max - 3;
    // back off to a UTF-8 boundary (don't slice mid-codepoint)
    while (i > 0 and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
    return text[0..i];
}

/// Format seconds-since-epoch as "Nu" relative-to-now ("2d", "5h", "12m", "just now").
/// `buf` should be ≥ 16 bytes; returns a slice of `buf`.
pub fn formatRelativeTime(buf: []u8, then_unix: i64, now_unix: i64) []const u8 {
    const delta = if (now_unix >= then_unix) now_unix - then_unix else 0;
    if (delta < 60) return std.fmt.bufPrint(buf, "just now", .{}) catch buf[0..0];
    if (delta < 60 * 60) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(delta, 60)}) catch buf[0..0];
    if (delta < 24 * 60 * 60) return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(delta, 60 * 60)}) catch buf[0..0];
    if (delta < 30 * 24 * 60 * 60) return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(delta, 24 * 60 * 60)}) catch buf[0..0];
    if (delta < 365 * 24 * 60 * 60) return std.fmt.bufPrint(buf, "{d}mo", .{@divTrunc(delta, 30 * 24 * 60 * 60)}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d}y", .{@divTrunc(delta, 365 * 24 * 60 * 60)}) catch buf[0..0];
}

/// Decide whether to actually run a refresh body. `force=true` always returns true.
/// Otherwise compares current mtime to last_mtime.
pub fn shouldRefresh(last_mtime: i128, current_mtime: i128, force: bool) bool {
    if (force) return true;
    return current_mtime != last_mtime;
}

test "truncateWithEllipsis short returns whole" {
    const out = truncateWithEllipsis("hi", 10);
    try std.testing.expectEqualStrings("hi", out);
}

test "truncateWithEllipsis exact fit" {
    const out = truncateWithEllipsis("abcdef", 6);
    try std.testing.expectEqualStrings("abcdef", out);
}

test "truncateWithEllipsis longer truncates leaving ellipsis room" {
    const out = truncateWithEllipsis("abcdefghij", 6);
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("abc", out);
}

test "formatRelativeTime just now" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 1000, 1010);
    try std.testing.expectEqualStrings("just now", out);
}

test "formatRelativeTime minutes" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 5 * 60);
    try std.testing.expectEqualStrings("5m", out);
}

test "formatRelativeTime hours" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 3 * 60 * 60);
    try std.testing.expectEqualStrings("3h", out);
}

test "formatRelativeTime days" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 2 * 24 * 60 * 60);
    try std.testing.expectEqualStrings("2d", out);
}

test "formatRelativeTime months" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 60 * 24 * 60 * 60);
    try std.testing.expectEqualStrings("2mo", out);
}

test "formatRelativeTime years" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 400 * 24 * 60 * 60);
    try std.testing.expectEqualStrings("1y", out);
}

test "shouldRefresh force always true" {
    try std.testing.expect(shouldRefresh(100, 100, true));
    try std.testing.expect(shouldRefresh(100, 200, true));
}

test "shouldRefresh mtime unchanged false" {
    try std.testing.expect(!shouldRefresh(100, 100, false));
}

test "shouldRefresh mtime changed true" {
    try std.testing.expect(shouldRefresh(100, 200, false));
}

pub const FooterField = struct {
    glyph: []const u8,
    text: []const u8,
};

/// Compute the per-column footer fields for a card.
/// `out` is caller-supplied storage with capacity ≥ 4.
/// `time_buf` is borrowed for relative-time formatting and small integer formatting.
/// All returned `text` slices either point into task fields (unowned here) or into `time_buf`.
pub fn cardFooterFields(
    task: d.Task,
    status: d.Status,
    glyphs: glyphs_mod.GlyphSet,
    now_unix: i64,
    out: []FooterField,
    time_buf: []u8,
) []FooterField {
    var n: usize = 0;
    switch (status) {
        .todo => {
            const text: []const u8 = if (task.branch_hint) |b| b.value else "—";
            out[n] = .{ .glyph = glyphs.branch, .text = text };
            n += 1;
        },
        .in_progress => {
            if (task.worktree) |w| {
                out[n] = .{ .glyph = glyphs.repo, .text = w.repo.name };
                n += 1;
                if (w.commits_ahead_of_default > 0 and n < out.len) {
                    const txt = std.fmt.bufPrint(time_buf, "{d}↑", .{w.commits_ahead_of_default}) catch "";
                    out[n] = .{ .glyph = "", .text = txt };
                    n += 1;
                }
            }
        },
        .in_review => {
            if (task.pr) |pr| {
                const txt = std.fmt.bufPrint(time_buf, "#{d}", .{pr.number}) catch "";
                out[n] = .{ .glyph = glyphs.pr, .text = txt };
                n += 1;
            }
            if (task.issue) |iss| {
                if (n < out.len) {
                    out[n] = .{ .glyph = glyphs.issue, .text = iss.external_id };
                    n += 1;
                }
            }
        },
        .done => {
            const then: i64 = if (task.pr) |pr| pr.updated_at.unix_secs else task.updated_at.unix_secs;
            const txt = formatRelativeTime(time_buf, then, now_unix);
            out[n] = .{ .glyph = "", .text = txt };
            n += 1;
        },
        .archived => {},
    }
    return out[0..n];
}

test "cardFooterFields TODO shows branch_hint" {
    var out: [4]FooterField = undefined;
    var time_buf: [16]u8 = undefined;
    const task = d.Task{
        .id = @enumFromInt(1),
        .title = "t",
        .branch_hint = .{ .value = "feat/x" },
        .worktree = null,
        .pr = null,
        .issue = null,
        .archived = false,
        .notes = null,
        .session = null,
        .created_at = .{ .unix_secs = 0 },
        .updated_at = .{ .unix_secs = 0 },
    };
    const got = cardFooterFields(task, .todo, glyphs_mod.GlyphSet.ascii, 100, &out, &time_buf);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("feat/x", got[0].text);
}

test "cardFooterFields TODO no branch shows em-dash" {
    var out: [4]FooterField = undefined;
    var time_buf: [16]u8 = undefined;
    const task = d.Task{
        .id = @enumFromInt(1),
        .title = "t",
        .branch_hint = null,
        .worktree = null,
        .pr = null,
        .issue = null,
        .archived = false,
        .notes = null,
        .session = null,
        .created_at = .{ .unix_secs = 0 },
        .updated_at = .{ .unix_secs = 0 },
    };
    const got = cardFooterFields(task, .todo, glyphs_mod.GlyphSet.ascii, 100, &out, &time_buf);
    try std.testing.expectEqualStrings("—", got[0].text);
}

test "cardFooterFields DONE shows relative time" {
    var out: [4]FooterField = undefined;
    var time_buf: [16]u8 = undefined;
    const task = d.Task{
        .id = @enumFromInt(1),
        .title = "t",
        .branch_hint = null,
        .worktree = null,
        .pr = null,
        .issue = null,
        .archived = false,
        .notes = null,
        .session = null,
        .created_at = .{ .unix_secs = 0 },
        .updated_at = .{ .unix_secs = 100 },
    };
    const got = cardFooterFields(task, .done, glyphs_mod.GlyphSet.ascii, 100, &out, &time_buf);
    try std.testing.expectEqualStrings("just now", got[0].text);
}
