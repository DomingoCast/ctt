const std = @import("std");
const d = @import("domain");

pub const AddTodoInput = struct {
    title: []const u8,
    branch_hint: ?d.BranchName = null,
    notes: ?[]const u8 = null,
};

pub const AddTodo = struct {
    tasks: d.ports.TaskRepository,

    pub fn execute(self: AddTodo, a: std.mem.Allocator, input: AddTodoInput) !d.Task {
        return self.tasks.create(a, .{
            .title = input.title,
            .branch_hint = input.branch_hint,
            .notes = input.notes,
        });
    }
};

test "AddTodo creates a Todo task" {
    const a = std.testing.allocator;
    var fake = @import("../tests/fake_task_repo.zig").FakeTaskRepo.init(a);
    defer fake.deinit();
    const uc = AddTodo{ .tasks = fake.interface() };
    const t = try uc.execute(a, .{ .title = "x" });
    try std.testing.expectEqualStrings("x", t.title);
    try std.testing.expect(t.worktree == null);
    try std.testing.expect(!t.archived);
}
