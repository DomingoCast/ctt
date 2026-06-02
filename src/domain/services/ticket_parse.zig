const std = @import("std");
const BranchName = @import("../value_objects/branch_name.zig").BranchName;
const ids = @import("../value_objects/ids.zig");

pub const TicketRef = struct {
    provider: ids.ProviderId,
    external_id: []const u8, // caller owns memory
};

pub const ProviderPattern = struct {
    provider: ids.ProviderId,
    // simple alphanumeric prefix + dash + digits matcher; not a full regex engine
    prefix_min: u8 = 2,
    prefix_max: u8 = 6,
};

/// Allocates the external_id (uppercased). Returns null if no match.
pub fn parse(
    allocator: std.mem.Allocator,
    branch: BranchName,
    patterns: []const ProviderPattern,
) !?TicketRef {
    for (patterns) |p| {
        if (try findMatch(allocator, branch.value, p)) |ref| return ref;
    }
    return null;
}

fn findMatch(allocator: std.mem.Allocator, s: []const u8, p: ProviderPattern) !?TicketRef {
    var i: usize = 0;
    while (i < s.len) {
        // skip non-alpha
        if (!std.ascii.isAlphabetic(s[i])) {
            i += 1;
            continue;
        }
        // try to read prefix
        const prefix_start = i;
        while (i < s.len and std.ascii.isAlphabetic(s[i])) : (i += 1) {}
        const prefix_len = i - prefix_start;
        if (prefix_len < p.prefix_min or prefix_len > p.prefix_max) continue;
        // require dash
        if (i >= s.len or s[i] != '-') continue;
        i += 1;
        // require digits
        const digits_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {}
        if (i == digits_start) continue;
        // boundary: end of string or non-alphanumeric
        if (i < s.len and (std.ascii.isAlphanumeric(s[i]))) continue;

        // build external_id = UPPER(prefix) ++ "-" ++ digits
        const out_len = prefix_len + 1 + (i - digits_start);
        var out = try allocator.alloc(u8, out_len);
        for (s[prefix_start .. prefix_start + prefix_len], 0..) |c, idx| out[idx] = std.ascii.toUpper(c);
        out[prefix_len] = '-';
        @memcpy(out[prefix_len + 1 ..], s[digits_start..i]);
        return TicketRef{ .provider = p.provider, .external_id = out };
    }
    return null;
}

test "matches MOE-272 in branch name" {
    const patterns = [_]ProviderPattern{.{ .provider = "linear" }};
    const got = (try parse(std.testing.allocator, BranchName.init("moe-272-foo"), &patterns)).?;
    defer std.testing.allocator.free(got.external_id);
    try std.testing.expectEqualStrings("linear", got.provider);
    try std.testing.expectEqualStrings("MOE-272", got.external_id);
}

test "matches inside slash path: fix/moe-272/sub" {
    const patterns = [_]ProviderPattern{.{ .provider = "linear" }};
    const got = (try parse(std.testing.allocator, BranchName.init("fix/moe-272/sub"), &patterns)).?;
    defer std.testing.allocator.free(got.external_id);
    try std.testing.expectEqualStrings("MOE-272", got.external_id);
}

test "returns null when no match" {
    const patterns = [_]ProviderPattern{.{ .provider = "linear" }};
    const got = try parse(std.testing.allocator, BranchName.init("just-words-here"), &patterns);
    try std.testing.expectEqual(@as(?TicketRef, null), got);
}

test "rejects prefix shorter than min" {
    const patterns = [_]ProviderPattern{.{ .provider = "linear", .prefix_min = 3 }};
    const got = try parse(std.testing.allocator, BranchName.init("ab-12-x"), &patterns);
    try std.testing.expectEqual(@as(?TicketRef, null), got);
}

test "first matching pattern wins" {
    const patterns = [_]ProviderPattern{
        .{ .provider = "linear" },
        .{ .provider = "jira" },
    };
    const got = (try parse(std.testing.allocator, BranchName.init("moe-1-x"), &patterns)).?;
    defer std.testing.allocator.free(got.external_id);
    try std.testing.expectEqualStrings("linear", got.provider);
}
