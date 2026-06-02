const std = @import("std");
const d = @import("domain");

/// In-memory TaskRepository test double.
/// Uses an internal arena for all string allocations so deinit() is leak-free.
pub const FakeTaskRepo = struct {
    arena: std.heap.ArenaAllocator,
    next_id: i64,
    tasks: std.AutoHashMap(i64, d.Task),

    pub fn init(a: std.mem.Allocator) FakeTaskRepo {
        return .{
            .arena = std.heap.ArenaAllocator.init(a),
            .next_id = 1,
            .tasks = std.AutoHashMap(i64, d.Task).init(a),
        };
    }

    pub fn deinit(self: *FakeTaskRepo) void {
        self.tasks.deinit();
        self.arena.deinit();
    }

    pub fn interface(self: *FakeTaskRepo) d.ports.TaskRepository {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = d.ports.TaskRepository.VTable{
        .create = createFn,
        .get    = getFn,
        .list   = listFn,
        .update = updateFn,
        .delete = deleteFn,
    };

    fn createFn(p: *anyopaque, _: std.mem.Allocator, draft: d.NewTask) d.ports.TaskRepository.Error!d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        const aa = self.arena.allocator();
        const id_val = self.next_id;
        self.next_id += 1;
        const t = d.Task{
            .id = @enumFromInt(id_val),
            .title = aa.dupe(u8, draft.title) catch return error.OutOfMemory,
            .branch_hint = draft.branch_hint,
            .worktree = null,
            .pr = null,
            .issue = null,
            .archived = false,
            .notes = if (draft.notes) |n| aa.dupe(u8, n) catch return error.OutOfMemory else null,
            .created_at = .{ .unix_secs = 0 },
            .updated_at = .{ .unix_secs = 0 },
        };
        self.tasks.put(id_val, t) catch return error.OutOfMemory;
        return t;
    }

    fn getFn(p: *anyopaque, _: std.mem.Allocator, id: d.ids.TaskId) d.ports.TaskRepository.Error!?d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        return self.tasks.get(id.raw());
    }

    fn listFn(p: *anyopaque, a: std.mem.Allocator, _: d.TaskFilter) d.ports.TaskRepository.Error![]d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        var out = a.alloc(d.Task, self.tasks.count()) catch return error.OutOfMemory;
        var it = self.tasks.valueIterator();
        var i: usize = 0;
        while (it.next()) |t| : (i += 1) out[i] = t.*;
        return out;
    }

    fn updateFn(p: *anyopaque, _: std.mem.Allocator, id: d.ids.TaskId, patch: d.TaskPatch) d.ports.TaskRepository.Error!d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        const existing = self.tasks.getPtr(id.raw()) orelse return error.NotFound;
        if (patch.title) |v| existing.title = v;
        if (patch.branch_hint) |v| existing.branch_hint = v;
        if (patch.notes) |v| existing.notes = v;
        if (patch.archived) |v| existing.archived = v;
        // Double-optional link patches: outer-some means "set or clear"
        if (patch.worktree_id) |inner| _ = inner; // skipped — RefreshAll task adds proper handling
        if (patch.pr_id) |inner| _ = inner;
        if (patch.issue_id) |inner| _ = inner;
        return existing.*;
    }

    fn deleteFn(p: *anyopaque, id: d.ids.TaskId) d.ports.TaskRepository.Error!void {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        _ = self.tasks.remove(id.raw());
    }
};
