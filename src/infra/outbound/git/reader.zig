const std = @import("std");
const d = @import("domain");

// ─── Porcelain text parser ────────────────────────────────────────────────────

pub fn parsePorcelain(a: std.mem.Allocator, text: []const u8) ![]d.WorktreeSnapshot {
    var out: std.ArrayList(d.WorktreeSnapshot) = .empty;
    defer out.deinit(a);

    var cur_path: ?[]const u8 = null;
    var cur_sha: ?[]const u8 = null;
    var cur_branch: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) {
            try flushBlock(a, &out, &cur_path, &cur_sha, &cur_branch);
            continue;
        }
        if (std.mem.startsWith(u8, line, "worktree ")) cur_path = line[9..];
        if (std.mem.startsWith(u8, line, "HEAD ")) cur_sha = line[5..];
        if (std.mem.startsWith(u8, line, "branch ")) cur_branch = stripRefs(line[7..]);
        // detached/locked/prunable/bare flags are silently ignored
    }
    // flush trailing block (in case input doesn't end with blank line)
    try flushBlock(a, &out, &cur_path, &cur_sha, &cur_branch);

    return out.toOwnedSlice(a);
}

fn flushBlock(
    a: std.mem.Allocator,
    out: *std.ArrayList(d.WorktreeSnapshot),
    p: *?[]const u8,
    s: *?[]const u8,
    b: *?[]const u8,
) !void {
    if (p.* != null and s.* != null and b.* != null) {
        try out.append(a, .{
            .path = try a.dupe(u8, p.*.?),
            .branch = .{ .value = try a.dupe(u8, b.*.?) },
            .head_sha = .{ .value = try a.dupe(u8, s.*.?) },
            .commits_ahead_of_default = 0,
            .has_upstream = false,
            .commits_ahead_of_upstream = null,
        });
    }
    p.* = null;
    s.* = null;
    b.* = null;
}

fn stripRefs(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "refs/heads/")) return s[11..];
    return s;
}

// ─── GitWorktreeReader adapter ────────────────────────────────────────────────

pub const GitWorktreeReader = struct {
    io: std.Io,

    pub fn init(io: std.Io) GitWorktreeReader {
        return .{ .io = io };
    }

    pub fn interface(self: *GitWorktreeReader) d.ports.WorktreeReader {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = d.ports.WorktreeReader.VTable{ .list = listFn };

    fn listFn(p: *anyopaque, a: std.mem.Allocator, repo: d.Repo) d.ports.WorktreeReader.Error![]d.WorktreeSnapshot {
        const self: *GitWorktreeReader = @ptrCast(@alignCast(p));
        const stdout = runGit(a, self.io, repo.root_path, &.{ "worktree", "list", "--porcelain" }) catch return error.Io;
        defer a.free(stdout);

        const snaps = parsePorcelain(a, stdout) catch return error.OutOfMemory;

        // Populate per-worktree git stats; failures fall back to safe defaults.
        for (snaps) |*snap| {
            populateAhead(a, self.io, snap, repo.default_branch) catch |err| std.log.scoped(.git).warn(
                "populateAhead failed for {s}: {s}",
                .{ snap.path, @errorName(err) },
            );
        }

        return snaps;
    }
};

fn populateAhead(a: std.mem.Allocator, io: std.Io, snap: *d.WorktreeSnapshot, default_branch: []const u8) !void {
    // 1. commits_ahead_of_default
    {
        const range = try std.fmt.allocPrint(a, "{s}..HEAD", .{default_branch});
        defer a.free(range);
        const out = runGit(a, io, snap.path, &.{ "rev-list", "--count", range }) catch return;
        defer a.free(out);
        snap.commits_ahead_of_default = parseCount(out);
    }
    // 2. has_upstream + commits_ahead_of_upstream
    if (runGit(a, io, snap.path, &.{ "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })) |up_out| {
        defer a.free(up_out);
        snap.has_upstream = true;
        const up_out2 = runGit(a, io, snap.path, &.{ "rev-list", "--count", "@{u}..HEAD" }) catch return;
        defer a.free(up_out2);
        snap.commits_ahead_of_upstream = parseCount(up_out2);
    } else |_| {
        snap.has_upstream = false;
        snap.commits_ahead_of_upstream = null;
    }
}

fn parseCount(s: []const u8) u32 {
    const trimmed = std.mem.trim(u8, s, " \n\r\t");
    return std.fmt.parseInt(u32, trimmed, 10) catch 0;
}

fn runGit(a: std.mem.Allocator, io: std.Io, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, "git");
    try argv.append(a, "-C");
    try argv.append(a, cwd);
    for (args) |arg| try argv.append(a, arg);

    const result = try std.process.run(a, io, .{
        .argv = argv.items,
    });
    defer a.free(result.stderr);
    errdefer a.free(result.stdout);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            a.free(result.stdout);
            return error.GitFailed;
        },
        else => {
            a.free(result.stdout);
            return error.GitFailed;
        },
    }
    return result.stdout;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

fn freeSnaps(a: std.mem.Allocator, snaps: []d.WorktreeSnapshot) void {
    for (snaps) |w| {
        a.free(w.path);
        a.free(w.branch.value);
        a.free(w.head_sha.value);
    }
    a.free(snaps);
}

test "parses three worktrees" {
    const sample =
        \\worktree /a
        \\HEAD aaa
        \\branch refs/heads/main
        \\
        \\worktree /b
        \\HEAD bbb
        \\branch refs/heads/feat/x
        \\
        \\worktree /c
        \\HEAD ccc
        \\branch refs/heads/fix-y
        \\
    ;
    const got = try parsePorcelain(std.testing.allocator, sample);
    defer freeSnaps(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("feat/x", got[1].branch.value);
    try std.testing.expectEqualStrings("ccc", got[2].head_sha.value);
}

test "skips worktrees without a branch (detached HEAD)" {
    const sample =
        \\worktree /a
        \\HEAD aaa
        \\branch refs/heads/main
        \\
        \\worktree /detached
        \\HEAD bbb
        \\detached
        \\
    ;
    const got = try parsePorcelain(std.testing.allocator, sample);
    defer freeSnaps(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("main", got[0].branch.value);
}

test "discovers worktrees in a tmp repo" {
    const io = std.testing.io;
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];

    // Set up a minimal git repo
    const setup_cmds: []const []const []const u8 = &.{
        &.{ "git", "init", "-b", "main" },
        &.{ "git", "config", "user.email", "test@test.com" },
        &.{ "git", "config", "user.name", "Test" },
    };
    for (setup_cmds) |cmd| {
        const res = try std.process.run(a, io, .{
            .argv = cmd,
            .cwd = .{ .path = root },
        });
        a.free(res.stdout);
        a.free(res.stderr);
    }

    // Create an initial commit (required for worktree add to work)
    {
        // Write an empty file
        var f = try tmp.dir.createFile(io, "README", .{});
        f.close(io);

        const add_res = try std.process.run(a, io, .{
            .argv = &.{ "git", "add", "README" },
            .cwd = .{ .path = root },
        });
        a.free(add_res.stdout);
        a.free(add_res.stderr);

        const commit_res = try std.process.run(a, io, .{
            .argv = &.{ "git", "commit", "-m", "init" },
            .cwd = .{ .path = root },
        });
        a.free(commit_res.stdout);
        a.free(commit_res.stderr);
    }

    var reader = GitWorktreeReader.init(io);
    const port = reader.interface();
    const snaps = try port.list(a, .{
        .id = @enumFromInt(1),
        .name = "test",
        .root_path = root,
        .github = null,
        .default_branch = "main",
    });
    defer freeSnaps(a, snaps);

    try std.testing.expect(snaps.len >= 1);
    try std.testing.expectEqualStrings("main", snaps[0].branch.value);
}
