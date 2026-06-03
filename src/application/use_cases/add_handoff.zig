const std = @import("std");
const d = @import("domain");

pub const AddHandoff = struct {
    handoffs: d.ports.HandoffRepository,
    clock: d.ports.Clock,

    pub fn execute(self: AddHandoff, a: std.mem.Allocator, task_id: d.ids.TaskId, body: []const u8) !d.ids.HandoffId {
        return self.handoffs.append(a, .{ .task_id = task_id, .body = body }, self.clock.now());
    }
};

test "AddHandoff appends a handoff and returns its id" {
    const a = std.testing.allocator;
    var fake_h = @import("../tests/fake_handoff_repo.zig").FakeHandoffRepo.init(a);
    defer fake_h.deinit();
    var fake_c = @import("../tests/fake_clock.zig").FakeClock.init(.{ .unix_secs = 1000 });
    const uc = AddHandoff{ .handoffs = fake_h.interface(), .clock = fake_c.interface() };
    const id = try uc.execute(a, @enumFromInt(7), "first checkpoint");
    try std.testing.expectEqual(@as(i64, 1), id.raw());
    try std.testing.expectEqual(@as(usize, 1), fake_h.entries.items.len);
    try std.testing.expectEqualStrings("first checkpoint", fake_h.entries.items[0].body);
    try std.testing.expectEqual(@as(i64, 1000), fake_h.entries.items[0].created_at.unix_secs);
}
