const std = @import("std");
const zqlite = @import("zqlite");
const migrations = @import("migrations.zig");

pub const Db = struct {
    conn: zqlite.Conn,

    pub fn open(path: [*:0]const u8) !Db {
        var conn = try zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
        errdefer conn.close();
        var db = Db{ .conn = conn };
        try db.migrate();
        return db;
    }

    pub fn close(self: *Db) void {
        self.conn.close();
    }

    fn migrate(self: *Db) !void {
        // Get current user_version via PRAGMA
        var version: i64 = 0;
        if (try self.conn.row("PRAGMA user_version", .{})) |row| {
            defer row.deinit();
            version = row.int(0);
        }

        if (version < 1) {
            try self.conn.execNoArgs(migrations.v1);
        }
        if (version < 2) {
            try self.conn.execNoArgs(migrations.v2);
        }
    }
};

fn tmpDbPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir, filename: []const u8) ![:0]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &path_buf);
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ path_buf[0..n], filename }, 0);
}

test "open creates db file and applies v1 migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a null-terminated path to a file inside the tmp dir
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "t.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();

    // Verify all 5 tables exist
    var rows = try db.conn.rows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", .{});
    defer rows.deinit();

    var seen: u8 = 0;
    while (rows.next()) |_| seen += 1;

    try std.testing.expect(seen >= 6);   // tasks, repos, worktrees, prs, issues, handoffs
}

test "v2 migration adds session columns and handoffs table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_z = try tmpDbPath(std.testing.allocator, tmp, "v2.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();

    // user_version is 2
    var ver_row = (try db.conn.row("PRAGMA user_version", .{})).?;
    defer ver_row.deinit();
    try std.testing.expectEqual(@as(i64, 2), ver_row.int(0));

    // handoffs table exists
    var rows = try db.conn.rows("SELECT name FROM sqlite_master WHERE type='table' AND name='handoffs'", .{});
    defer rows.deinit();
    try std.testing.expect(rows.next() != null);

    // session_provider column exists on tasks
    var col_rows = try db.conn.rows("PRAGMA table_info(tasks)", .{});
    defer col_rows.deinit();
    var found_sp = false;
    while (col_rows.next()) |r| {
        const name = r.text(1);
        if (std.mem.eql(u8, name, "session_provider")) found_sp = true;
    }
    try std.testing.expect(found_sp);
}

test "re-opening an existing db is idempotent (no double migration)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_z = try tmpDbPath(std.testing.allocator, tmp, "t.sqlite");
    defer std.testing.allocator.free(path_z);

    {
        var db = try Db.open(path_z);
        db.close();
    }
    {
        var db = try Db.open(path_z);
        defer db.close();

        // Schema still valid; insert+query a row to prove it
        try db.conn.execNoArgs("INSERT INTO repos (name, root_path) VALUES ('r1', '/r1')");
        var rows = try db.conn.rows("SELECT name FROM repos", .{});
        defer rows.deinit();
        const row = rows.next() orelse return error.MissingRow;
        try std.testing.expectEqualStrings("r1", row.text(0));
    }
}
