const std = @import("std");
const d = @import("domain");

pub const SetSessionHandle = struct {
    tasks: d.ports.TaskRepository,

    pub fn execute(self: SetSessionHandle, a: std.mem.Allocator, id: d.ids.TaskId, handle: ?d.SessionHandle) !d.Task {
        return self.tasks.update(a, id, .{ .session = @as(??d.SessionHandle, handle) });
    }
};

test "SetSessionHandle sets a session on a task" {
    const a = std.testing.allocator;
    var fake = @import("../tests/fake_task_repo.zig").FakeTaskRepo.init(a);
    defer fake.deinit();
    const repo = fake.interface();
    _ = try repo.create(a, .{ .title = "my task" });
    const uc = SetSessionHandle{ .tasks = repo };
    const updated = try uc.execute(a, @enumFromInt(1), .{ .provider = "claude", .session_id = "s1" });
    const sh = updated.session orelse return error.ExpectedSession;
    try std.testing.expectEqualStrings("claude", sh.provider);
    try std.testing.expectEqualStrings("s1", sh.session_id);
}

test "SetSessionHandle clears a session" {
    const a = std.testing.allocator;
    var fake = @import("../tests/fake_task_repo.zig").FakeTaskRepo.init(a);
    defer fake.deinit();
    const repo = fake.interface();
    _ = try repo.create(a, .{ .title = "my task" });
    const uc = SetSessionHandle{ .tasks = repo };
    _ = try uc.execute(a, @enumFromInt(1), .{ .provider = "claude", .session_id = "s1" });
    const cleared = try uc.execute(a, @enumFromInt(1), null);
    try std.testing.expect(cleared.session == null);
}
