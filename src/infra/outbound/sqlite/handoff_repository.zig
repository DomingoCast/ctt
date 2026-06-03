const std = @import("std");
const d = @import("domain");
const Db = @import("db.zig").Db;

pub const SqliteHandoffRepository = struct {
    db: *Db,

    pub fn init(db: *Db) SqliteHandoffRepository {
        return .{ .db = db };
    }

    pub fn interface(self: *SqliteHandoffRepository) d.ports.HandoffRepository {
        return .{ .ptr = self, .vtable = &VT };
    }

    const VT = d.ports.HandoffRepository.VTable{
        .append = appendFn,
        .list   = listFn,
        .latest = latestFn,
    };

    fn mapErr(e: anyerror) d.ports.HandoffRepository.Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Io,
        };
    }

    fn appendFn(
        p: *anyopaque,
        _: std.mem.Allocator,
        draft: d.NewHandoff,
        now: d.Timestamp,
    ) d.ports.HandoffRepository.Error!d.ids.HandoffId {
        const self: *SqliteHandoffRepository = @ptrCast(@alignCast(p));
        self.db.conn.exec(
            "INSERT INTO handoffs (task_id, body, created_at) VALUES (?, ?, ?)",
            .{ draft.task_id.raw(), draft.body, now.unix_secs },
        ) catch |e| return mapErr(e);
        return @enumFromInt(self.db.conn.lastInsertedRowId());
    }

    fn listFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        task_id: d.ids.TaskId,
        limit: ?usize,
    ) d.ports.HandoffRepository.Error![]d.HandoffEntry {
        const self: *SqliteHandoffRepository = @ptrCast(@alignCast(p));
        const lim: i64 = if (limit) |l| @intCast(l) else -1;
        var rows = self.db.conn.rows(
            "SELECT id, task_id, body, created_at FROM handoffs WHERE task_id = ? ORDER BY created_at DESC, id DESC LIMIT ?",
            .{ task_id.raw(), lim },
        ) catch |e| return mapErr(e);
        defer rows.deinit();

        var out: std.ArrayList(d.HandoffEntry) = .empty;
        errdefer {
            for (out.items) |h| a.free(h.body);
            out.deinit(a);
        }

        while (rows.next()) |row| {
            const body = a.dupe(u8, row.text(2)) catch return error.OutOfMemory;
            errdefer a.free(body);
            out.append(a, .{
                .id         = @enumFromInt(row.int(0)),
                .task_id    = @enumFromInt(row.int(1)),
                .body       = body,
                .created_at = .{ .unix_secs = row.int(3) },
            }) catch return error.OutOfMemory;
        }
        if (rows.err) |e| return mapErr(e);

        return out.toOwnedSlice(a) catch return error.OutOfMemory;
    }

    fn latestFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        task_id: d.ids.TaskId,
    ) d.ports.HandoffRepository.Error!?d.HandoffEntry {
        const self: *SqliteHandoffRepository = @ptrCast(@alignCast(p));
        const maybe_row = self.db.conn.row(
            "SELECT id, task_id, body, created_at FROM handoffs WHERE task_id = ? ORDER BY created_at DESC, id DESC LIMIT 1",
            .{task_id.raw()},
        ) catch |e| return mapErr(e);
        const row = maybe_row orelse return null;
        defer row.deinit();
        const body = a.dupe(u8, row.text(2)) catch return error.OutOfMemory;
        return d.HandoffEntry{
            .id         = @enumFromInt(row.int(0)),
            .task_id    = @enumFromInt(row.int(1)),
            .body       = body,
            .created_at = .{ .unix_secs = row.int(3) },
        };
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────

const tmpDbPath = @import("db.zig").tmpDbPath;

test "append then latest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "h.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();

    try db.conn.exec("INSERT INTO tasks (title) VALUES (?)", .{"t"});
    const task_id: d.ids.TaskId = @enumFromInt(db.conn.lastInsertedRowId());

    var repo = SqliteHandoffRepository.init(&db);
    const iface = repo.interface();

    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "first" }, .{ .unix_secs = 100 });
    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "second" }, .{ .unix_secs = 200 });

    const latest = (try iface.latest(std.testing.allocator, task_id)).?;
    defer std.testing.allocator.free(latest.body);
    try std.testing.expectEqualStrings("second", latest.body);
}

test "list returns entries newest first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "h2.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();
    try db.conn.exec("INSERT INTO tasks (title) VALUES (?)", .{"t"});
    const task_id: d.ids.TaskId = @enumFromInt(db.conn.lastInsertedRowId());

    var repo = SqliteHandoffRepository.init(&db);
    const iface = repo.interface();

    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "a" }, .{ .unix_secs = 1 });
    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "b" }, .{ .unix_secs = 2 });
    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "c" }, .{ .unix_secs = 3 });

    const all = try iface.list(std.testing.allocator, task_id, null);
    defer {
        for (all) |h| std.testing.allocator.free(h.body);
        std.testing.allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("c", all[0].body);
    try std.testing.expectEqualStrings("b", all[1].body);
    try std.testing.expectEqualStrings("a", all[2].body);
}

test "cascade delete removes handoffs when task is deleted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "h3.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();
    try db.conn.exec("INSERT INTO tasks (title) VALUES (?)", .{"t"});
    const task_id: d.ids.TaskId = @enumFromInt(db.conn.lastInsertedRowId());

    var repo = SqliteHandoffRepository.init(&db);
    const iface = repo.interface();
    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "x" }, .{ .unix_secs = 1 });

    try db.conn.exec("DELETE FROM tasks WHERE id = ?", .{task_id.raw()});

    const got = try iface.latest(std.testing.allocator, task_id);
    try std.testing.expect(got == null);
}
