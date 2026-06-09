const std = @import("std");
const cfg = @import("infra_config");

pub const Candidate = struct {
    name: []const u8,
    path: []const u8,
};

/// Names that are never useful as project entries.
const DENYLIST = [_][]const u8{
    "node_modules", "target", ".git", "build", "dist",
    "zig-cache",    "zig-out", ".zig-cache",
};

pub const BuildError = error{OutOfMemory};

/// Build the candidate list:
///   1. Start with every repo in `cfg_repos`.
///   2. For each directory in `project_roots`, add one entry per direct subdirectory
///      whose name is not in DENYLIST and does not start with `.`.
///   3. Dedupe by absolute path; entries from `cfg_repos` win on collision.
///
/// Returned candidates' name/path strings are owned by `a` (duped). Free them
/// via `freeCandidates`, then free the outer slice with `a.free(out)`.
pub fn build(
    a: std.mem.Allocator,
    io: std.Io,
    cfg_repos: []const cfg.RepoConfig,
    project_roots: []const []const u8,
) BuildError![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    errdefer {
        freeCandidates(a, out.items);
        out.deinit(a);
    }

    // 1. Configured repos first (they win on collision).
    for (cfg_repos) |r| {
        try out.append(a, .{
            .name = try a.dupe(u8, r.name),
            .path = try a.dupe(u8, r.path),
        });
    }

    // 2. Scan each project_root one level deep.
    for (project_roots) |root| {
        var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .directory) continue;
            if (e.name.len == 0 or e.name[0] == '.') continue;
            if (inDenylist(e.name)) continue;

            const full = std.fmt.allocPrint(a, "{s}/{s}", .{ root, e.name }) catch return error.OutOfMemory;
            errdefer a.free(full);

            // Dedupe: if any existing candidate has the same path, skip.
            if (hasPath(out.items, full)) {
                a.free(full);
                continue;
            }

            const name = a.dupe(u8, e.name) catch {
                a.free(full);
                return error.OutOfMemory;
            };
            try out.append(a, .{ .name = name, .path = full });
        }
    }

    return out.toOwnedSlice(a);
}

fn inDenylist(name: []const u8) bool {
    for (DENYLIST) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

fn hasPath(items: []const Candidate, path: []const u8) bool {
    for (items) |c| {
        if (std.mem.eql(u8, c.path, path)) return true;
    }
    return false;
}

pub fn freeCandidates(a: std.mem.Allocator, c: []const Candidate) void {
    for (c) |x| {
        a.free(x.name);
        a.free(x.path);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "build from cfg_repos only" {
    const repos = [_]cfg.RepoConfig{
        .{ .name = "ctt", .path = "/Users/me/ctt" },
        .{ .name = "foo", .path = "/Users/me/foo" },
    };
    const got = try build(std.testing.allocator, std.testing.io, &repos, &.{});
    defer {
        freeCandidates(std.testing.allocator, got);
        std.testing.allocator.free(got);
    }
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("ctt", got[0].name);
    try std.testing.expectEqualStrings("/Users/me/ctt", got[0].path);
}

test "build scans project_roots and skips denylist/dotdirs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Layout:
    //   <tmp>/
    //     alpha/
    //     beta/
    //     node_modules/    (denylisted)
    //     .hidden/         (dotdir)
    try tmp.dir.createDirPath(std.testing.io, "alpha");
    try tmp.dir.createDirPath(std.testing.io, "beta");
    try tmp.dir.createDirPath(std.testing.io, "node_modules");
    try tmp.dir.createDirPath(std.testing.io, ".hidden");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root_abs = buf[0..n];
    const root_dup = try std.testing.allocator.dupe(u8, root_abs);
    defer std.testing.allocator.free(root_dup);

    const roots = [_][]const u8{root_dup};
    const got = try build(std.testing.allocator, std.testing.io, &.{}, &roots);
    defer {
        freeCandidates(std.testing.allocator, got);
        std.testing.allocator.free(got);
    }

    try std.testing.expectEqual(@as(usize, 2), got.len);
    var saw_alpha = false;
    var saw_beta = false;
    for (got) |c| {
        if (std.mem.eql(u8, c.name, "alpha")) saw_alpha = true;
        if (std.mem.eql(u8, c.name, "beta")) saw_beta = true;
    }
    try std.testing.expect(saw_alpha);
    try std.testing.expect(saw_beta);
}

test "build dedupes by path; repos win" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "ctt");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const root_abs = buf[0..n];
    const root_dup = try std.testing.allocator.dupe(u8, root_abs);
    defer std.testing.allocator.free(root_dup);

    const ctt_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/ctt", .{root_dup});
    defer std.testing.allocator.free(ctt_path);

    // Repo registers the same absolute path with a custom display name.
    const repos = [_]cfg.RepoConfig{
        .{ .name = "my-cool-ctt", .path = ctt_path },
    };
    const roots = [_][]const u8{root_dup};
    const got = try build(std.testing.allocator, std.testing.io, &repos, &roots);
    defer {
        freeCandidates(std.testing.allocator, got);
        std.testing.allocator.free(got);
    }

    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("my-cool-ctt", got[0].name);
}

test "build tolerates non-existent root" {
    const roots = [_][]const u8{"/nonexistent/path/never/exists"};
    const got = try build(std.testing.allocator, std.testing.io, &.{}, &roots);
    defer {
        freeCandidates(std.testing.allocator, got);
        std.testing.allocator.free(got);
    }
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
