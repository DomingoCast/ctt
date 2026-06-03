const std = @import("std");
const d = @import("domain");
const Db = @import("db.zig").Db;
const SqliteTaskRepository = @import("task_repository.zig").SqliteTaskRepository;
const freeTask = @import("task_repository.zig").freeTask;

// ─── Helper: open an in-memory (well, tmp-file) database ───────────────────

fn openTempDb(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !Db {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const path_z = try std.fmt.allocPrintSentinel(allocator, "{s}/t.sqlite", .{buf[0..n]}, 0);
    defer allocator.free(path_z);
    return Db.open(path_z);
}

// ─── Test 1: create → get round-trips title ────────────────────────────────

test "create then get round-trips title" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openTempDb(std.testing.allocator, &tmp);
    defer db.close();

    var repo = SqliteTaskRepository.init(&db);
    const port = repo.interface();

    const created = try port.create(std.testing.allocator, .{ .title = "hello" });
    defer freeTask(std.testing.allocator, created);

    const got = (try port.get(std.testing.allocator, created.id)).?;
    defer freeTask(std.testing.allocator, got);

    try std.testing.expectEqualStrings("hello", got.title);
    try std.testing.expect(got.worktree == null);
    try std.testing.expect(got.pr == null);
    try std.testing.expect(got.issue == null);
    try std.testing.expect(!got.archived);
}

// ─── Test 2: update sets title + archived ──────────────────────────────────

test "update sets title and archived" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openTempDb(std.testing.allocator, &tmp);
    defer db.close();

    var repo = SqliteTaskRepository.init(&db);
    const port = repo.interface();

    const created = try port.create(std.testing.allocator, .{ .title = "original" });
    defer freeTask(std.testing.allocator, created);

    const updated = try port.update(std.testing.allocator, created.id, .{
        .title    = "changed",
        .archived = true,
    });
    defer freeTask(std.testing.allocator, updated);

    try std.testing.expectEqualStrings("changed", updated.title);
    try std.testing.expect(updated.archived);
}

// ─── Test 3: delete removes the task ───────────────────────────────────────

test "delete removes the task" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openTempDb(std.testing.allocator, &tmp);
    defer db.close();

    var repo = SqliteTaskRepository.init(&db);
    const port = repo.interface();

    const created = try port.create(std.testing.allocator, .{ .title = "to delete" });
    defer freeTask(std.testing.allocator, created);

    try port.delete(created.id);
    const gone = try port.get(std.testing.allocator, created.id);
    try std.testing.expect(gone == null);
}

// ─── Test 4: list filters by repo_name ─────────────────────────────────────

test "list filters by repo_name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openTempDb(std.testing.allocator, &tmp);
    defer db.close();

    // Insert a repo.
    try db.conn.exec(
        "INSERT INTO repos (name, root_path) VALUES (?, ?)",
        .{ "myrepo", "/tmp/myrepo" },
    );
    const repo_id = db.conn.lastInsertedRowId();

    // Insert a worktree linked to that repo.
    try db.conn.exec(
        \\INSERT INTO worktrees (repo_id, path, branch, head_sha,
        \\    commits_ahead_of_default, has_upstream, last_seen_at)
        \\VALUES (?, ?, ?, ?, 0, 0, '0')
    ,
        .{ repo_id, "/tmp/myrepo/wt", "feat/x", "abc123" },
    );
    const wt_id = db.conn.lastInsertedRowId();

    // Insert two tasks: one linked to the worktree (visible in repo filter),
    // one unlinked.
    try db.conn.exec(
        "INSERT INTO tasks (title, worktree_id) VALUES (?, ?)",
        .{ "linked task", wt_id },
    );
    try db.conn.exec("INSERT INTO tasks (title) VALUES (?)", .{"unlinked task"});

    var task_repo = SqliteTaskRepository.init(&db);
    const port = task_repo.interface();

    // Filter: only tasks in "myrepo".
    const filtered = try port.list(std.testing.allocator, .{ .repo_name = "myrepo" });
    defer {
        for (filtered) |t| freeTask(std.testing.allocator, t);
        std.testing.allocator.free(filtered);
    }

    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqualStrings("linked task", filtered[0].title);

    // No filter: both tasks.
    const all = try port.list(std.testing.allocator, .{});
    defer {
        for (all) |t| freeTask(std.testing.allocator, t);
        std.testing.allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);
}

// ─── Test 5: upsertWorktree is idempotent ──────────────────────────────────

test "upsert_worktree is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openTempDb(std.testing.allocator, &tmp);
    defer db.close();

    try db.conn.exec(
        "INSERT INTO repos (name, root_path) VALUES (?, ?)",
        .{ "repo1", "/r1" },
    );
    const repo_id: d.ids.RepoId = @enumFromInt(db.conn.lastInsertedRowId());

    var task_repo = SqliteTaskRepository.init(&db);
    const port = task_repo.interface();

    const snap = d.WorktreeSnapshot{
        .path   = "/r1/main",
        .branch = .{ .value = "main" },
        .head_sha = .{ .value = "deadbeef" },
        .commits_ahead_of_default = 0,
        .has_upstream = false,
        .commits_ahead_of_upstream = null,
    };

    const id1 = try port.upsertWorktree(std.testing.allocator, repo_id, snap);
    const id2 = try port.upsertWorktree(std.testing.allocator, repo_id, snap);

    // Same (repo_id, branch) → same id.
    try std.testing.expectEqual(id1, id2);

    // Verify only one row exists.
    const row = (try db.conn.row("SELECT COUNT(*) FROM worktrees", .{})).?;
    defer row.deinit();
    try std.testing.expectEqual(@as(i64, 1), row.int(0));
}

// ─── Test 6: findByBranchHint matches a todo (no worktree) ─────────────────

test "find_by_branch_hint finds todo by branch_hint when worktree_id is NULL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openTempDb(std.testing.allocator, &tmp);
    defer db.close();

    var task_repo = SqliteTaskRepository.init(&db);
    const port = task_repo.interface();

    // Create a task with a branch hint (no worktree).
    const created = try port.create(std.testing.allocator, .{
        .title       = "branchy task",
        .branch_hint = .{ .value = "feat/my-branch" },
    });
    defer freeTask(std.testing.allocator, created);

    const found = try port.findByBranchHint(std.testing.allocator, .{ .value = "feat/my-branch" });
    if (found) |f| {
        defer freeTask(std.testing.allocator, f);
        try std.testing.expectEqualStrings("branchy task", f.title);
    } else {
        return error.TaskNotFound;
    }

    // A branch that doesn't exist → null.
    const not_found = try port.findByBranchHint(std.testing.allocator, .{ .value = "other" });
    try std.testing.expect(not_found == null);
}

// ─── Test 7: get reconstructs linked worktree ──────────────────────────────

test "get reconstructs linked worktree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openTempDb(std.testing.allocator, &tmp);
    defer db.close();

    // Insert repo.
    try db.conn.exec(
        "INSERT INTO repos (name, root_path) VALUES (?, ?)",
        .{ "myrepo", "/myrepo" },
    );
    const repo_id = db.conn.lastInsertedRowId();

    // Insert worktree.
    try db.conn.exec(
        \\INSERT INTO worktrees (repo_id, path, branch, head_sha,
        \\    commits_ahead_of_default, has_upstream, last_seen_at)
        \\VALUES (?, ?, ?, ?, 2, 1, '0')
    ,
        .{ repo_id, "/myrepo/feat-x", "feat/x", "cafe0123" },
    );
    const wt_id = db.conn.lastInsertedRowId();

    // Insert task linked to worktree.
    try db.conn.exec(
        "INSERT INTO tasks (title, worktree_id) VALUES (?, ?)",
        .{ "linked", wt_id },
    );
    const task_id: d.ids.TaskId = @enumFromInt(db.conn.lastInsertedRowId());

    var task_repo = SqliteTaskRepository.init(&db);
    const port = task_repo.interface();

    const got = (try port.get(std.testing.allocator, task_id)).?;
    defer freeTask(std.testing.allocator, got);

    try std.testing.expect(got.worktree != null);
    const wt = got.worktree.?;
    try std.testing.expectEqualStrings("feat/x", wt.branch.value);
    try std.testing.expectEqualStrings("cafe0123", wt.head_sha.value);
    try std.testing.expectEqualStrings("myrepo", wt.repo.name);
    try std.testing.expectEqual(@as(u32, 2), wt.commits_ahead_of_default);
    try std.testing.expect(wt.has_upstream);
}

// ─── Test 8: session handle round-trip ────────────────────────────────────

test "task session handle round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openTempDb(std.testing.allocator, &tmp);
    defer db.close();

    var repo = SqliteTaskRepository.init(&db);
    const iface = repo.interface();

    const created = try iface.create(std.testing.allocator, .{ .title = "t" });
    try std.testing.expect(created.session == null);
    freeTask(std.testing.allocator, created);

    // Re-get to get a fresh copy (created was freed above, but id is still valid)
    const fetched = (try iface.get(std.testing.allocator, created.id)).?;
    defer freeTask(std.testing.allocator, fetched);

    const handle = d.SessionHandle{ .provider = "claude", .session_id = "abc-123" };
    const updated = try iface.update(std.testing.allocator, created.id, .{ .session = @as(??d.SessionHandle, handle) });
    defer freeTask(std.testing.allocator, updated);

    const got = (try iface.get(std.testing.allocator, created.id)).?;
    defer freeTask(std.testing.allocator, got);

    if (got.session) |s| {
        try std.testing.expectEqualStrings("claude", s.provider);
        try std.testing.expectEqualStrings("abc-123", s.session_id);
    } else try std.testing.expect(false);
}

// ─── Test 9: session handle clear ─────────────────────────────────────────

test "task session handle clear" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try openTempDb(std.testing.allocator, &tmp);
    defer db.close();

    var repo = SqliteTaskRepository.init(&db);
    const iface = repo.interface();

    const created = try iface.create(std.testing.allocator, .{ .title = "t" });
    freeTask(std.testing.allocator, created);

    const with_session = try iface.update(std.testing.allocator, created.id, .{ .session = @as(??d.SessionHandle, .{ .provider = "x", .session_id = "y" }) });
    freeTask(std.testing.allocator, with_session);

    // Use @as(?d.SessionHandle, null) to express Some(null) = "clear the field".
    const cleared = try iface.update(std.testing.allocator, created.id, .{ .session = @as(?d.SessionHandle, null) });
    freeTask(std.testing.allocator, cleared);

    const got = (try iface.get(std.testing.allocator, created.id)).?;
    defer freeTask(std.testing.allocator, got);
    try std.testing.expect(got.session == null);
}
