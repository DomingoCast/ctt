const std = @import("std");
const d = @import("domain");

pub const ListHandoffs = struct {
    handoffs: d.ports.HandoffRepository,

    pub fn execute(self: ListHandoffs, a: std.mem.Allocator, task_id: d.ids.TaskId, limit: ?usize) ![]d.HandoffEntry {
        return self.handoffs.list(a, task_id, limit);
    }
};

test "ListHandoffs returns entries newest first" {
    const a = std.testing.allocator;
    var fake_h = @import("../tests/fake_handoff_repo.zig").FakeHandoffRepo.init(a);
    defer fake_h.deinit();
    var fake_c = @import("../tests/fake_clock.zig").FakeClock.init(.{ .unix_secs = 0 });
    const repo = fake_h.interface();
    const task_id: d.ids.TaskId = @enumFromInt(3);
    _ = try repo.append(a, .{ .task_id = task_id, .body = "first" }, fake_c.interface().now());
    _ = try repo.append(a, .{ .task_id = task_id, .body = "second" }, fake_c.interface().now());
    const uc = ListHandoffs{ .handoffs = repo };
    const entries = try uc.execute(a, task_id, null);
    defer {
        for (entries) |e| a.free(e.body);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    // newest first
    try std.testing.expectEqualStrings("second", entries[0].body);
    try std.testing.expectEqualStrings("first", entries[1].body);
}

test "ListHandoffs respects limit" {
    const a = std.testing.allocator;
    var fake_h = @import("../tests/fake_handoff_repo.zig").FakeHandoffRepo.init(a);
    defer fake_h.deinit();
    var fake_c = @import("../tests/fake_clock.zig").FakeClock.init(.{ .unix_secs = 0 });
    const repo = fake_h.interface();
    const task_id: d.ids.TaskId = @enumFromInt(5);
    _ = try repo.append(a, .{ .task_id = task_id, .body = "a" }, fake_c.interface().now());
    _ = try repo.append(a, .{ .task_id = task_id, .body = "b" }, fake_c.interface().now());
    _ = try repo.append(a, .{ .task_id = task_id, .body = "c" }, fake_c.interface().now());
    const uc = ListHandoffs{ .handoffs = repo };
    const entries = try uc.execute(a, task_id, 2);
    defer {
        for (entries) |e| a.free(e.body);
        a.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}
