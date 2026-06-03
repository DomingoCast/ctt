const std = @import("std");
const d = @import("domain");

pub const TaskContext = struct {
    task: d.Task,             // includes session, worktree, pr, issue
    handoffs: []d.HandoffEntry, // newest first
    // Caller owns all allocations; both task strings and the handoffs slice are
    // allocated by the allocator passed to execute().
};

pub const GetContext = struct {
    tasks: d.ports.TaskRepository,
    handoffs: d.ports.HandoffRepository,

    pub fn execute(
        self: GetContext,
        a: std.mem.Allocator,
        id: d.ids.TaskId,
        handoff_limit: ?usize,
    ) !?TaskContext {
        const t = (try self.tasks.get(a, id)) orelse return null;
        const hs = self.handoffs.list(a, id, handoff_limit) catch |e| {
            freeTask(a, t);
            return e;
        };
        return TaskContext{ .task = t, .handoffs = hs };
    }
};

// keep in sync with the other freeTask: src/infra/outbound/sqlite/task_repository.zig
// (a proper refactor moving this to a shared module or Task.deinit is tracked separately)
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
    if (t.session) |s| {
        a.free(s.provider);
        a.free(s.session_id);
    }
}

test "GetContext returns null when task not found" {
    const a = std.testing.allocator;
    var fake_t = @import("../tests/fake_task_repo.zig").FakeTaskRepo.init(a);
    defer fake_t.deinit();
    var fake_h = @import("../tests/fake_handoff_repo.zig").FakeHandoffRepo.init(a);
    defer fake_h.deinit();
    const uc = GetContext{ .tasks = fake_t.interface(), .handoffs = fake_h.interface() };
    const ctx = try uc.execute(a, @enumFromInt(99), null);
    try std.testing.expect(ctx == null);
}

test "GetContext returns task and handoffs" {
    const a = std.testing.allocator;
    var fake_t = @import("../tests/fake_task_repo.zig").FakeTaskRepo.init(a);
    defer fake_t.deinit();
    var fake_h = @import("../tests/fake_handoff_repo.zig").FakeHandoffRepo.init(a);
    defer fake_h.deinit();
    const task_repo = fake_t.interface();
    const handoff_repo = fake_h.interface();
    _ = try task_repo.create(a, .{ .title = "do work" });
    const task_id: d.ids.TaskId = @enumFromInt(1);
    _ = try handoff_repo.append(a, .{ .task_id = task_id, .body = "checkpoint" }, .{ .unix_secs = 0 });
    const uc = GetContext{ .tasks = task_repo, .handoffs = handoff_repo };
    const maybe_ctx = try uc.execute(a, task_id, null);
    const ctx = maybe_ctx orelse return error.ExpectedContext;
    defer {
        for (ctx.handoffs) |e| a.free(e.body);
        a.free(ctx.handoffs);
    }
    // Note: ctx.task fields are NOT freed in this test because FakeTaskRepo
    // returns arena-owned strings (it ignores the passed allocator). For an
    // integration test against a real repo, you MUST call freeTask(a, ctx.task)
    // before letting ctx go out of scope.
    try std.testing.expectEqualStrings("do work", ctx.task.title);
    try std.testing.expectEqual(@as(usize, 1), ctx.handoffs.len);
    try std.testing.expectEqualStrings("checkpoint", ctx.handoffs[0].body);
}
