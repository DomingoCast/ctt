const std = @import("std");
const app = @import("application");
const view = @import("view.zig");
const d = @import("domain");

pub const Mode = enum { normal }; // 8.4 will add `add_todo_modal`

pub const State = struct {
    allocator: std.mem.Allocator,
    views: []app.TaskView,
    sel: view.Selection = .{},
    mode: Mode = .normal,
    refreshing: bool = false,
    last_message: ?[]const u8 = null,

    pub fn init(a: std.mem.Allocator) State {
        return .{ .allocator = a, .views = &.{} };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.views);
        if (self.last_message) |m| self.allocator.free(m);
    }

    pub fn setViews(self: *State, new_views: []app.TaskView) void {
        self.allocator.free(self.views);
        self.views = new_views;
    }

    pub fn setMessage(self: *State, msg: []const u8) !void {
        if (self.last_message) |m| self.allocator.free(m);
        self.last_message = try self.allocator.dupe(u8, msg);
    }

    /// Count of tasks in column `col_idx` (0..3). Used to clamp selection on column move.
    pub fn columnCount(self: *const State, col_idx: u2) u32 {
        const target: d.Status = switch (col_idx) {
            0 => .todo,
            1 => .in_progress,
            2 => .in_review,
            3 => .done,
        };
        var count: u32 = 0;
        for (self.views) |v| if (v.status == target) {
            count += 1;
        };
        return count;
    }

    /// Return the TaskView at the current selection (column, row), or null if out of range.
    pub fn selectedView(self: *const State) ?app.TaskView {
        const target: d.Status = switch (self.sel.column) {
            0 => .todo,
            1 => .in_progress,
            2 => .in_review,
            3 => .done,
        };
        var row: u32 = 0;
        for (self.views) |v| {
            if (v.status != target) continue;
            if (row == self.sel.row) return v;
            row += 1;
        }
        return null;
    }
};

test "columnCount returns 0 for empty views" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectEqual(@as(u32, 0), s.columnCount(0));
    try std.testing.expectEqual(@as(u32, 0), s.columnCount(3));
}

test "selectedView returns null for empty views" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expectEqual(@as(?app.TaskView, null), s.selectedView());
}
