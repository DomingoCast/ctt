const std = @import("std");
const cfg = @import("infra_config");

pub const Match = struct {
    name: []const u8,
    path: []const u8,
};

pub const MAX_RESULTS: usize = 5;

/// Case-insensitive substring fuzzy match.
/// Ranks: name-prefix (bucket 0) > name-substring (bucket 1) > path-substring (bucket 2).
/// Within a bucket, preserves original config order (stable).
/// Empty query returns the first MAX_RESULTS repos in config order.
/// Returns at most MAX_RESULTS entries from `out` (caller-supplied with capacity >= MAX_RESULTS).
pub fn fuzzyMatch(repos: []const cfg.RepoConfig, query: []const u8, out: []Match) []Match {
    std.debug.assert(out.len >= MAX_RESULTS);

    if (query.len == 0) {
        const n = @min(repos.len, MAX_RESULTS);
        for (repos[0..n], 0..) |repo, i| {
            out[i] = .{ .name = repo.name, .path = repo.path };
        }
        return out[0..n];
    }

    var lower_q_buf: [256]u8 = undefined;
    if (query.len > lower_q_buf.len) return out[0..0];
    const lq = std.ascii.lowerString(&lower_q_buf, query);

    const Scored = struct { bucket: u8, idx: usize };
    var scored: [256]Scored = undefined;
    var n: usize = 0;

    for (repos, 0..) |repo, i| {
        if (n >= scored.len) break;
        const score = scoreRepo(repo, lq);
        if (score < 255) {
            scored[n] = .{ .bucket = score, .idx = i };
            n += 1;
        }
    }

    // Stable sort by bucket asc; preserve config order within bucket.
    std.mem.sort(Scored, scored[0..n], {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            if (a.bucket != b.bucket) return a.bucket < b.bucket;
            return a.idx < b.idx;
        }
    }.lt);

    const take = @min(n, MAX_RESULTS);
    for (scored[0..take], 0..) |s, i| {
        out[i] = .{ .name = repos[s.idx].name, .path = repos[s.idx].path };
    }
    return out[0..take];
}

fn scoreRepo(repo: cfg.RepoConfig, lq: []const u8) u8 {
    var name_buf: [256]u8 = undefined;
    var path_buf: [1024]u8 = undefined;
    if (repo.name.len > name_buf.len or repo.path.len > path_buf.len) return 255;
    const ln = std.ascii.lowerString(&name_buf, repo.name);
    const lp = std.ascii.lowerString(&path_buf, repo.path);

    if (std.mem.startsWith(u8, ln, lq)) return 0;
    if (std.mem.indexOf(u8, ln, lq) != null) return 1;
    if (std.mem.indexOf(u8, lp, lq) != null) return 2;
    return 255;
}

// ─── Tests ────────────────────────────────────────────────────────────────

fn r(name: []const u8, path: []const u8) cfg.RepoConfig {
    return .{ .name = name, .path = path };
}

test "empty query returns first 5" {
    const repos = [_]cfg.RepoConfig{
        r("a", "/a"), r("b", "/b"), r("c", "/c"),
        r("d", "/d"), r("e", "/e"), r("f", "/f"),
        r("g", "/g"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "", &out);
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqualStrings("a", got[0].name);
    try std.testing.expectEqualStrings("e", got[4].name);
}

test "name prefix wins over path substring" {
    const repos = [_]cfg.RepoConfig{
        r("foo", "/path/with/ctt/in/it"),
        r("ctt", "/elsewhere"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("ctt", got[0].name);
    try std.testing.expectEqualStrings("foo", got[1].name);
}

test "name substring wins over path substring" {
    const repos = [_]cfg.RepoConfig{
        r("foo", "/path/with/ctt"),
        r("my-ctt-tool", "/elsewhere"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("my-ctt-tool", got[0].name);
    try std.testing.expectEqualStrings("foo", got[1].name);
}

test "path-only match" {
    const repos = [_]cfg.RepoConfig{
        r("x", "/a/ctt/b"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("x", got[0].name);
}

test "no match returns empty" {
    const repos = [_]cfg.RepoConfig{ r("a", "/a"), r("b", "/b") };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "zzz", &out);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "truncates at MAX_RESULTS" {
    const repos = [_]cfg.RepoConfig{
        r("ctt-1", "/"), r("ctt-2", "/"), r("ctt-3", "/"),
        r("ctt-4", "/"), r("ctt-5", "/"), r("ctt-6", "/"),
        r("ctt-7", "/"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqualStrings("ctt-1", got[0].name);
    try std.testing.expectEqualStrings("ctt-5", got[4].name);
}

test "case insensitive match" {
    const repos = [_]cfg.RepoConfig{
        r("CTT", "/users/me/CTT"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("CTT", got[0].name);
}
