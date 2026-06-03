const std = @import("std");

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
