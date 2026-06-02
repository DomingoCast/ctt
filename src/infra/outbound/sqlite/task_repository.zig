const std = @import("std");
const d = @import("domain");
const zqlite = @import("zqlite");
const Db = @import("db.zig").Db;

// ─── Column layout for the big JOIN query ──────────────────────────────────
//
//  0  t.id
//  1  t.title
//  2  t.branch_hint
//  3  t.archived
//  4  t.notes
//  5  t.created_at
//  6  t.updated_at
//  7  w.id
//  8  w.repo_id
//  9  w.path
// 10  w.branch
// 11  w.head_sha
// 12  w.commits_ahead_of_default
// 13  w.has_upstream
// 14  w.commits_ahead_of_upstream
// 15  w.last_seen_at
// 16  rw.name  (w_repo_name)
// 17  p.id
// 18  p.repo_id
// 19  p.number
// 20  p.url
// 21  p.title
// 22  p.head_branch
// 23  p.state
// 24  p.updated_at
// 25  p.fetched_at
// 26  rp.name  (p_repo_name)
// 27  i.id
// 28  i.provider
// 29  i.external_id
// 30  i.url
// 31  i.title
// 32  i.state
// 33  i.fetched_at

const TASK_SELECT =
    \\SELECT
    \\    t.id, t.title, t.branch_hint, t.archived, t.notes, t.created_at, t.updated_at,
    \\    w.id, w.repo_id, w.path, w.branch, w.head_sha, w.commits_ahead_of_default,
    \\        w.has_upstream, w.commits_ahead_of_upstream, w.last_seen_at,
    \\    rw.name,
    \\    p.id, p.repo_id, p.number, p.url, p.title, p.head_branch, p.state, p.updated_at, p.fetched_at,
    \\    rp.name,
    \\    i.id, i.provider, i.external_id, i.url, i.title, i.state, i.fetched_at
    \\FROM tasks t
    \\LEFT JOIN worktrees w ON t.worktree_id = w.id
    \\LEFT JOIN repos rw    ON w.repo_id = rw.id
    \\LEFT JOIN prs p       ON t.pr_id = p.id
    \\LEFT JOIN repos rp    ON p.repo_id = rp.id
    \\LEFT JOIN issues i    ON t.issue_id = i.id
;

pub const SqliteTaskRepository = struct {
    db: *Db,

    pub fn init(db: *Db) SqliteTaskRepository {
        return .{ .db = db };
    }

    pub fn interface(self: *SqliteTaskRepository) d.ports.TaskRepository {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = d.ports.TaskRepository.VTable{
        .create              = createFn,
        .get                 = getFn,
        .list                = listFn,
        .update              = updateFn,
        .delete              = deleteFn,
        .find_by_branch_hint = findByBranchHintFn,
        .find_by_worktree    = findByWorktreeFn,
        .upsert_worktree     = upsertWorktreeFn,
        .upsert_pr           = upsertPrFn,
        .upsert_issue        = upsertIssueFn,
    };

    fn mapErr(e: anyerror) d.ports.TaskRepository.Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotFound    => error.NotFound,
            error.Conflict    => error.Conflict,
            else              => error.Io,
        };
    }

    // ─── create ───────────────────────────────────────────────────────────

    fn createFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        draft: d.NewTask,
    ) d.ports.TaskRepository.Error!d.Task {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        const conn = self.db.conn;

        const branch_hint_text: ?[]const u8 = if (draft.branch_hint) |b| b.value else null;

        conn.exec(
            "INSERT INTO tasks (title, branch_hint, notes) VALUES (?, ?, ?)",
            .{ draft.title, branch_hint_text, draft.notes },
        ) catch |e| return mapErr(e);

        const id = conn.lastInsertedRowId();
        return (try getFn(p, a, @enumFromInt(id))) orelse error.Io;
    }

    // ─── get ──────────────────────────────────────────────────────────────

    fn getFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        id: d.ids.TaskId,
    ) d.ports.TaskRepository.Error!?d.Task {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        const conn = self.db.conn;

        const sql = TASK_SELECT ++ " WHERE t.id = ?";

        const row = conn.row(sql, .{id.raw()}) catch |e| return mapErr(e);
        if (row) |r| {
            defer r.deinit();
            return rowToTask(a, r) catch |e| return mapErr(e);
        }
        return null;
    }

    // ─── list ─────────────────────────────────────────────────────────────

    fn listFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        f: d.TaskFilter,
    ) d.ports.TaskRepository.Error![]d.Task {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        const conn = self.db.conn;

        // Build SQL dynamically based on which filters are active.
        // All 4 combinations (repo_name×text) are small and predictable.
        var sql_buf: [2048]u8 = undefined;
        const sql = blk: {
            const base = TASK_SELECT ++ " WHERE 1=1";
            const repo_clause = " AND (rw.name = ? OR rp.name = ?)";
            const text_clause = " AND t.title LIKE '%'||?||'%'";
            const order_clause = " ORDER BY t.updated_at DESC";
            const with_repo_text = base ++ repo_clause ++ text_clause ++ order_clause;
            const with_repo      = base ++ repo_clause ++ order_clause;
            const with_text      = base ++ text_clause ++ order_clause;
            const base_order     = base ++ order_clause;
            break :blk switch (@as(u2, @intFromBool(f.repo_name != null)) << 1 |
                               @intFromBool(f.text != null)) {
                0b11 => std.fmt.bufPrint(&sql_buf, "{s}", .{with_repo_text}) catch unreachable,
                0b10 => std.fmt.bufPrint(&sql_buf, "{s}", .{with_repo}) catch unreachable,
                0b01 => std.fmt.bufPrint(&sql_buf, "{s}", .{with_text}) catch unreachable,
                0b00 => std.fmt.bufPrint(&sql_buf, "{s}", .{base_order}) catch unreachable,
            };
        };

        // We need to prepare and bind dynamically since the parameter count varies.
        const stmt = conn.prepare(sql) catch |e| return mapErr(e);
        defer stmt.deinit();

        var bind_idx: usize = 0;
        if (f.repo_name) |rn| {
            stmt.bindValue(rn, bind_idx) catch |e| return mapErr(e);
            bind_idx += 1;
            stmt.bindValue(rn, bind_idx) catch |e| return mapErr(e);
            bind_idx += 1;
        }
        if (f.text) |txt| {
            stmt.bindValue(txt, bind_idx) catch |e| return mapErr(e);
            bind_idx += 1;
        }

        var result: std.ArrayList(d.Task) = .empty;
        errdefer {
            for (result.items) |t| freeTask(a, t);
            result.deinit(a);
        }

        while (stmt.step() catch |e| return mapErr(e)) {
            const row = zqlite.Row{ .stmt = stmt };
            const task = rowToTask(a, row) catch |e| return mapErr(e);

            // Apply status filter in Zig (derived field).
            if (f.status) |wanted| {
                const derived = d.derive_status(task);
                if (derived != wanted) {
                    freeTask(a, task);
                    continue;
                }
            }

            result.append(a, task) catch |e| return mapErr(e);
        }

        if (result.items.len == 0) {
            result.deinit(a);
            return &[_]d.Task{};
        }

        return result.toOwnedSlice(a) catch |e| return mapErr(e);
    }

    // ─── update ───────────────────────────────────────────────────────────

    fn updateFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        id: d.ids.TaskId,
        patch: d.TaskPatch,
    ) d.ports.TaskRepository.Error!d.Task {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        const conn = self.db.conn;

        // Apply each non-null field as a separate UPDATE to keep code simple.
        if (patch.title) |v| {
            conn.exec("UPDATE tasks SET title = ?, updated_at = datetime('now') WHERE id = ?", .{ v, id.raw() }) catch |e| return mapErr(e);
        }
        if (patch.branch_hint) |v| {
            conn.exec("UPDATE tasks SET branch_hint = ?, updated_at = datetime('now') WHERE id = ?", .{ v.value, id.raw() }) catch |e| return mapErr(e);
        }
        if (patch.notes) |v| {
            conn.exec("UPDATE tasks SET notes = ?, updated_at = datetime('now') WHERE id = ?", .{ v, id.raw() }) catch |e| return mapErr(e);
        }
        if (patch.archived) |v| {
            conn.exec("UPDATE tasks SET archived = ?, updated_at = datetime('now') WHERE id = ?", .{ v, id.raw() }) catch |e| return mapErr(e);
        }
        // Double-optional link patches
        if (patch.worktree_id) |maybe_wt| {
            if (maybe_wt) |wt_id| {
                conn.exec("UPDATE tasks SET worktree_id = ?, updated_at = datetime('now') WHERE id = ?", .{ wt_id.raw(), id.raw() }) catch |e| return mapErr(e);
            } else {
                conn.exec("UPDATE tasks SET worktree_id = NULL, updated_at = datetime('now') WHERE id = ?", .{id.raw()}) catch |e| return mapErr(e);
            }
        }
        if (patch.pr_id) |maybe_pr| {
            if (maybe_pr) |pr_id| {
                conn.exec("UPDATE tasks SET pr_id = ?, updated_at = datetime('now') WHERE id = ?", .{ pr_id.raw(), id.raw() }) catch |e| return mapErr(e);
            } else {
                conn.exec("UPDATE tasks SET pr_id = NULL, updated_at = datetime('now') WHERE id = ?", .{id.raw()}) catch |e| return mapErr(e);
            }
        }
        if (patch.issue_id) |maybe_iss| {
            if (maybe_iss) |iss_id| {
                conn.exec("UPDATE tasks SET issue_id = ?, updated_at = datetime('now') WHERE id = ?", .{ iss_id.raw(), id.raw() }) catch |e| return mapErr(e);
            } else {
                conn.exec("UPDATE tasks SET issue_id = NULL, updated_at = datetime('now') WHERE id = ?", .{id.raw()}) catch |e| return mapErr(e);
            }
        }

        return (try getFn(p, a, id)) orelse error.NotFound;
    }

    // ─── delete ───────────────────────────────────────────────────────────

    fn deleteFn(p: *anyopaque, id: d.ids.TaskId) d.ports.TaskRepository.Error!void {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        self.db.conn.exec("DELETE FROM tasks WHERE id = ?", .{id.raw()}) catch |e| return mapErr(e);
    }

    // ─── findByBranchHint ─────────────────────────────────────────────────

    fn findByBranchHintFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        branch: d.BranchName,
    ) d.ports.TaskRepository.Error!?d.Task {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        const conn = self.db.conn;

        const sql = TASK_SELECT ++
            " WHERE t.branch_hint = ? AND t.worktree_id IS NULL LIMIT 1";

        const row = conn.row(sql, .{branch.value}) catch |e| return mapErr(e);
        if (row) |r| {
            defer r.deinit();
            return rowToTask(a, r) catch |e| return mapErr(e);
        }
        return null;
    }

    // ─── findByWorktree ───────────────────────────────────────────────────

    fn findByWorktreeFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        wt_id: d.ids.WorktreeId,
    ) d.ports.TaskRepository.Error!?d.Task {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        const conn = self.db.conn;

        const sql = TASK_SELECT ++ " WHERE t.worktree_id = ? LIMIT 1";

        const row = conn.row(sql, .{wt_id.raw()}) catch |e| return mapErr(e);
        if (row) |r| {
            defer r.deinit();
            return rowToTask(a, r) catch |e| return mapErr(e);
        }
        return null;
    }

    // ─── upsertWorktree ───────────────────────────────────────────────────

    fn upsertWorktreeFn(
        p: *anyopaque,
        _: std.mem.Allocator,
        repo_id: d.ids.RepoId,
        snap: d.WorktreeSnapshot,
    ) d.ports.TaskRepository.Error!d.ids.WorktreeId {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        const conn = self.db.conn;

        const ahead_upstream: ?i64 = if (snap.commits_ahead_of_upstream) |v|
            @intCast(v)
        else
            null;

        // Use SQLite's datetime('now') for last_seen_at — stored as text.
        conn.exec(
            \\INSERT INTO worktrees (repo_id, path, branch, head_sha,
            \\    commits_ahead_of_default, has_upstream, commits_ahead_of_upstream, last_seen_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))
            \\ON CONFLICT (repo_id, branch) DO UPDATE SET
            \\    path = excluded.path,
            \\    head_sha = excluded.head_sha,
            \\    commits_ahead_of_default = excluded.commits_ahead_of_default,
            \\    has_upstream = excluded.has_upstream,
            \\    commits_ahead_of_upstream = excluded.commits_ahead_of_upstream,
            \\    last_seen_at = excluded.last_seen_at
        ,
            .{
                repo_id.raw(),
                snap.path,
                snap.branch.value,
                snap.head_sha.value,
                @as(i64, @intCast(snap.commits_ahead_of_default)),
                snap.has_upstream,
                ahead_upstream,
            },
        ) catch |e| return mapErr(e);

        // Retrieve the actual id (INSERT OR REPLACE may give us the new rowid on insert,
        // but on conflict/update we need to SELECT it).
        const id_row = conn.row(
            "SELECT id FROM worktrees WHERE repo_id = ? AND branch = ?",
            .{ repo_id.raw(), snap.branch.value },
        ) catch |e| return mapErr(e);
        if (id_row) |r| {
            defer r.deinit();
            return @enumFromInt(r.int(0));
        }
        return error.Io;
    }

    // ─── upsertPr ─────────────────────────────────────────────────────────

    fn upsertPrFn(
        p: *anyopaque,
        _: std.mem.Allocator,
        repo_id: d.ids.RepoId,
        snap: d.PrSnapshot,
        fetched_at: d.Timestamp,
    ) d.ports.TaskRepository.Error!d.ids.PrId {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        const conn = self.db.conn;

        var ts_buf: [32]u8 = undefined;
        const fetched_str = std.fmt.bufPrint(&ts_buf, "{d}", .{fetched_at.unix_secs}) catch "0";

        var upd_buf: [32]u8 = undefined;
        const upd_str = std.fmt.bufPrint(&upd_buf, "{d}", .{snap.updated_at.unix_secs}) catch "0";

        const state_str = @tagName(snap.state);

        conn.exec(
            \\INSERT INTO prs (repo_id, number, url, title, head_branch, state, updated_at, fetched_at)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            \\ON CONFLICT (repo_id, number) DO UPDATE SET
            \\    url        = excluded.url,
            \\    title      = excluded.title,
            \\    head_branch = excluded.head_branch,
            \\    state      = excluded.state,
            \\    updated_at = excluded.updated_at,
            \\    fetched_at = excluded.fetched_at
        ,
            .{
                repo_id.raw(),
                @as(i64, @intCast(snap.number)),
                snap.url.value,
                snap.title,
                snap.head_branch.value,
                state_str,
                upd_str,
                fetched_str,
            },
        ) catch |e| return mapErr(e);

        const id_row = conn.row(
            "SELECT id FROM prs WHERE repo_id = ? AND number = ?",
            .{ repo_id.raw(), @as(i64, @intCast(snap.number)) },
        ) catch |e| return mapErr(e);
        if (id_row) |r| {
            defer r.deinit();
            return @enumFromInt(r.int(0));
        }
        return error.Io;
    }

    // ─── upsertIssue ──────────────────────────────────────────────────────

    fn upsertIssueFn(
        p: *anyopaque,
        _: std.mem.Allocator,
        provider: d.ids.ProviderId,
        snap: d.IssueSnapshot,
        fetched_at: d.Timestamp,
    ) d.ports.TaskRepository.Error!d.ids.IssueId {
        const self: *SqliteTaskRepository = @ptrCast(@alignCast(p));
        const conn = self.db.conn;

        var ts_buf: [32]u8 = undefined;
        const fetched_str = std.fmt.bufPrint(&ts_buf, "{d}", .{fetched_at.unix_secs}) catch "0";

        conn.exec(
            \\INSERT INTO issues (provider, external_id, url, title, state, fetched_at)
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT (provider, external_id) DO UPDATE SET
            \\    url        = excluded.url,
            \\    title      = excluded.title,
            \\    state      = excluded.state,
            \\    fetched_at = excluded.fetched_at
        ,
            .{
                provider,
                snap.external_id,
                snap.url,
                snap.title,
                snap.state,
                fetched_str,
            },
        ) catch |e| return mapErr(e);

        const id_row = conn.row(
            "SELECT id FROM issues WHERE provider = ? AND external_id = ?",
            .{ provider, snap.external_id },
        ) catch |e| return mapErr(e);
        if (id_row) |r| {
            defer r.deinit();
            return @enumFromInt(r.int(0));
        }
        return error.Io;
    }
};

// ─── Helpers ───────────────────────────────────────────────────────────────

/// Parse "YYYY-MM-DD HH:MM:SS" (SQLite datetime('now')) or a plain integer
/// string into Unix epoch seconds. Returns 0 on parse failure.
fn parseUnixSecs(s: []const u8) i64 {
    // Fast path: plain integer (what WE store for timestamps we control).
    if (std.fmt.parseInt(i64, s, 10) catch null) |v| return v;

    // Slow path: "YYYY-MM-DD HH:MM:SS"
    if (s.len < 19) return 0;
    const Y  = std.fmt.parseInt(i32, s[0..4],   10) catch return 0;
    const Mo = std.fmt.parseInt(i32, s[5..7],   10) catch return 0;
    const D  = std.fmt.parseInt(i32, s[8..10],  10) catch return 0;
    const h  = std.fmt.parseInt(i32, s[11..13], 10) catch return 0;
    const m  = std.fmt.parseInt(i32, s[14..16], 10) catch return 0;
    const sc = std.fmt.parseInt(i32, s[17..19], 10) catch return 0;

    // Julian Day Number (proleptic Gregorian)
    const a_calc  = @divTrunc(14 - Mo, 12);
    const y       = Y + 4800 - a_calc;
    const m_calc  = Mo + 12 * a_calc - 3;
    const jdn     = D + @divTrunc(153 * m_calc + 2, 5) + 365 * y +
                    @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) - 32045;
    // Unix epoch is JDN 2440588
    const days_since_epoch: i64 = @intCast(jdn - 2440588);
    return days_since_epoch * 86400 +
           @as(i64, @intCast(h))  * 3600 +
           @as(i64, @intCast(m))  * 60   +
           @as(i64, @intCast(sc));
}

/// Parse a PrState from its tag name stored in SQLite.
fn parsePrState(s: []const u8) d.PrState {
    if (std.mem.eql(u8, s, "open"))   return .open;
    if (std.mem.eql(u8, s, "draft"))  return .draft;
    if (std.mem.eql(u8, s, "merged")) return .merged;
    return .closed;
}

/// Reconstruct a `d.Task` from a single row of the big JOIN query.
/// All string data is duplicated into `a` so it survives the Row's deinit.
fn rowToTask(a: std.mem.Allocator, row: zqlite.Row) !d.Task {
    // ── task columns (0-6) ──
    const task_id: i64         = row.int(0);
    const title_raw            = row.text(1);
    const branch_hint_raw      = row.nullableText(2);
    const archived_int: i64    = row.int(3);
    const notes_raw            = row.nullableText(4);
    const created_raw          = row.text(5);
    const updated_raw          = row.text(6);

    const title = try a.dupe(u8, title_raw);
    errdefer a.free(title);

    const branch_hint: ?d.BranchName = if (branch_hint_raw) |bh| blk: {
        const bh_dup = try a.dupe(u8, bh);
        break :blk d.BranchName{ .value = bh_dup };
    } else null;
    errdefer if (branch_hint) |bh| a.free(bh.value);

    const notes: ?[]const u8 = if (notes_raw) |n| try a.dupe(u8, n) else null;
    errdefer if (notes) |n| a.free(n);

    // ── worktree columns (7-16) ──
    const worktree: ?d.Worktree = if (row.nullableInt(7)) |wt_id| blk: {
        const wt_repo_id: i64 = row.int(8);
        const wt_path         = try a.dupe(u8, row.text(9));
        errdefer a.free(wt_path);
        const wt_branch       = try a.dupe(u8, row.text(10));
        errdefer a.free(wt_branch);
        const wt_sha          = try a.dupe(u8, row.text(11));
        errdefer a.free(wt_sha);
        const wt_ahead: i64   = row.int(12);
        const wt_has_up: bool = row.boolean(13);
        const wt_up_raw       = row.nullableInt(14);
        const wt_last_raw     = row.text(15);
        const wt_repo_name    = try a.dupe(u8, row.text(16));
        errdefer a.free(wt_repo_name);

        break :blk d.Worktree{
            .id   = @enumFromInt(wt_id),
            .repo = .{ .id = @enumFromInt(wt_repo_id), .name = wt_repo_name },
            .path = wt_path,
            .branch = .{ .value = wt_branch },
            .head_sha = .{ .value = wt_sha },
            .commits_ahead_of_default = @intCast(wt_ahead),
            .has_upstream = wt_has_up,
            .commits_ahead_of_upstream = if (wt_up_raw) |v| @intCast(v) else null,
            .last_seen_at = .{ .unix_secs = parseUnixSecs(wt_last_raw) },
        };
    } else null;
    errdefer if (worktree) |wt| {
        a.free(wt.path);
        a.free(wt.branch.value);
        a.free(wt.head_sha.value);
        a.free(wt.repo.name);
    };

    // ── pr columns (17-26) ──
    const pr: ?d.Pr = if (row.nullableInt(17)) |pr_id| blk: {
        const pr_repo_id: i64  = row.int(18);
        const pr_number: i64   = row.int(19);
        const pr_url           = try a.dupe(u8, row.text(20));
        errdefer a.free(pr_url);
        const pr_title         = try a.dupe(u8, row.text(21));
        errdefer a.free(pr_title);
        const pr_head_branch   = try a.dupe(u8, row.text(22));
        errdefer a.free(pr_head_branch);
        const pr_state         = parsePrState(row.text(23));
        const pr_upd_raw       = row.text(24);
        const pr_fetched_raw   = row.text(25);
        const pr_repo_name     = try a.dupe(u8, row.text(26));
        errdefer a.free(pr_repo_name);

        break :blk d.Pr{
            .id   = @enumFromInt(pr_id),
            .repo = .{ .id = @enumFromInt(pr_repo_id), .name = pr_repo_name },
            .number = @intCast(pr_number),
            .url = .{ .value = pr_url },
            .title = pr_title,
            .head_branch = .{ .value = pr_head_branch },
            .state = pr_state,
            .updated_at = .{ .unix_secs = parseUnixSecs(pr_upd_raw) },
            .fetched_at = .{ .unix_secs = parseUnixSecs(pr_fetched_raw) },
        };
    } else null;
    errdefer if (pr) |p| {
        a.free(p.url.value);
        a.free(p.title);
        a.free(p.head_branch.value);
        a.free(p.repo.name);
    };

    // ── issue columns (27-33) ──
    const issue: ?d.Issue = if (row.nullableInt(27)) |iss_id| blk: {
        const iss_provider    = try a.dupe(u8, row.text(28));
        errdefer a.free(iss_provider);
        const iss_ext_id      = try a.dupe(u8, row.text(29));
        errdefer a.free(iss_ext_id);
        const iss_url         = if (row.nullableText(30)) |v| try a.dupe(u8, v) else null;
        errdefer if (iss_url) |u| a.free(u);
        const iss_title       = if (row.nullableText(31)) |v| try a.dupe(u8, v) else null;
        errdefer if (iss_title) |t| a.free(t);
        const iss_state       = if (row.nullableText(32)) |v| try a.dupe(u8, v) else null;
        errdefer if (iss_state) |s| a.free(s);
        const iss_fetched_raw = row.text(33);

        break :blk d.Issue{
            .id          = @enumFromInt(iss_id),
            .provider    = iss_provider,
            .external_id = iss_ext_id,
            .url         = iss_url,
            .title       = iss_title,
            .state       = iss_state,
            .fetched_at  = .{ .unix_secs = parseUnixSecs(iss_fetched_raw) },
        };
    } else null;
    errdefer if (issue) |iss| {
        a.free(iss.provider);
        a.free(iss.external_id);
        if (iss.url)   |u| a.free(u);
        if (iss.title) |t| a.free(t);
        if (iss.state) |s| a.free(s);
    };

    return d.Task{
        .id          = @enumFromInt(task_id),
        .title       = title,
        .branch_hint = branch_hint,
        .worktree    = worktree,
        .pr          = pr,
        .issue       = issue,
        .archived    = archived_int != 0,
        .notes       = notes,
        .created_at  = .{ .unix_secs = parseUnixSecs(created_raw) },
        .updated_at  = .{ .unix_secs = parseUnixSecs(updated_raw) },
    };
}

/// Free all heap allocations inside a `d.Task`.
pub fn freeTask(a: std.mem.Allocator, t: d.Task) void {
    a.free(t.title);
    if (t.branch_hint) |b| a.free(b.value);
    if (t.notes)       |n| a.free(n);
    if (t.worktree)    |w| {
        a.free(w.path);
        a.free(w.branch.value);
        a.free(w.head_sha.value);
        a.free(w.repo.name);
    }
    if (t.pr) |p| {
        a.free(p.url.value);
        a.free(p.title);
        a.free(p.head_branch.value);
        a.free(p.repo.name);
    }
    if (t.issue) |i| {
        a.free(i.provider);
        a.free(i.external_id);
        if (i.url)   |u| a.free(u);
        if (i.title) |tt| a.free(tt);
        if (i.state) |s| a.free(s);
    }
}
