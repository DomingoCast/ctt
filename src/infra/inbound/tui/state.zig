const std = @import("std");
const app = @import("application");
const view = @import("view.zig");
const d = @import("domain");
const glyphs_mod = @import("glyphs.zig");
const theme_mod = @import("theme.zig");

pub const Mode = enum { normal, add_todo_modal, detail, handoff_modal, help_modal };

pub const ModalFocus = enum { title, branch, issue, project };

pub const DetailState = struct {
    task: d.Task,
    handoffs: []d.HandoffEntry,

    pub fn deinit(self: *DetailState, a: std.mem.Allocator) void {
        for (self.handoffs) |h| a.free(h.body);
        a.free(self.handoffs);
        app.freeTask(a, self.task);
    }
};

pub const HandoffModal = struct {
    task_id: d.ids.TaskId,
    body_buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *HandoffModal, a: std.mem.Allocator) void {
        self.body_buf.deinit(a);
    }
};

pub const AddTodoModal = struct {
    focus: ModalFocus = .title,
    title_buf: std.ArrayList(u8) = .empty,
    branch_buf: std.ArrayList(u8) = .empty,
    issue_buf: std.ArrayList(u8) = .empty,
    project_buf: std.ArrayList(u8) = .empty,
    project_selection: u8 = 0,
    project_dropdown_open: bool = false,

    pub fn deinit(self: *AddTodoModal, a: std.mem.Allocator) void {
        self.title_buf.deinit(a);
        self.branch_buf.deinit(a);
        self.issue_buf.deinit(a);
        self.project_buf.deinit(a);
    }

    pub fn reset(self: *AddTodoModal, a: std.mem.Allocator) void {
        self.deinit(a);
        self.* = .{};
    }

    pub fn focused(self: *AddTodoModal) *std.ArrayList(u8) {
        return switch (self.focus) {
            .title => &self.title_buf,
            .branch => &self.branch_buf,
            .issue => &self.issue_buf,
            .project => &self.project_buf,
        };
    }

    pub fn cycleFocus(self: *AddTodoModal) void {
        self.focus = switch (self.focus) {
            .title => .branch,
            .branch => .issue,
            .issue => .project,
            .project => .title,
        };
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    views: []app.TaskView,
    sel: view.Selection = .{},
    mode: Mode = .normal,
    cfg_repos: []const @import("infra_config").RepoConfig = &.{},
    /// True while doRefresh is in flight; consumed by the footer pulse (Phase F).
    refreshing: bool = false,
    last_db_mtime: i128 = 0,
    /// Animation frame for the footer pulse indicator (rendered by Phase F).
    spinner_frame: u8 = 0,
    glyphs: glyphs_mod.GlyphSet = glyphs_mod.GlyphSet.nerd,
    colors: theme_mod.ColorScheme = theme_mod.ColorScheme.default,
    refresh_interval_ms: u32 = 2000,
    last_message: ?[]const u8 = null,
    add_todo_modal: AddTodoModal = .{},
    detail: ?DetailState = null,
    handoff_modal: ?HandoffModal = null,

    pub fn init(a: std.mem.Allocator) State {
        return .{ .allocator = a, .views = &.{} };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.views);
        if (self.last_message) |m| self.allocator.free(m);
        self.add_todo_modal.deinit(self.allocator);
        if (self.detail) |*ds| ds.deinit(self.allocator);
        if (self.handoff_modal) |*hm| hm.deinit(self.allocator);
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

test "modal cycleFocus rotates through title->branch->issue->project->title" {
    var m = AddTodoModal{};
    defer m.deinit(std.testing.allocator);
    try std.testing.expectEqual(ModalFocus.title, m.focus);
    m.cycleFocus();
    try std.testing.expectEqual(ModalFocus.branch, m.focus);
    m.cycleFocus();
    try std.testing.expectEqual(ModalFocus.issue, m.focus);
    m.cycleFocus();
    try std.testing.expectEqual(ModalFocus.project, m.focus);
    m.cycleFocus();
    try std.testing.expectEqual(ModalFocus.title, m.focus);
}

test "modal focused buffer returns the right pointer" {
    var m = AddTodoModal{};
    defer m.deinit(std.testing.allocator);
    try m.title_buf.appendSlice(std.testing.allocator, "hello");
    try std.testing.expectEqualStrings("hello", m.focused().items);
    m.focus = .branch;
    try m.branch_buf.appendSlice(std.testing.allocator, "feat/x");
    try std.testing.expectEqualStrings("feat/x", m.focused().items);
}

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
