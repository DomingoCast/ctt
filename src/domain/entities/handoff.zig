const std = @import("std");
const ids = @import("../value_objects/ids.zig");
const Timestamp = @import("../value_objects/timestamp.zig").Timestamp;

pub const HandoffEntry = struct {
    id: ids.HandoffId,
    task_id: ids.TaskId,
    body: []const u8,
    created_at: Timestamp,
};

pub const NewHandoff = struct {
    task_id: ids.TaskId,
    body: []const u8,
};

test "HandoffEntry construction" {
    const h = HandoffEntry{
        .id = @enumFromInt(1),
        .task_id = @enumFromInt(42),
        .body = "checkpoint",
        .created_at = .{ .unix_secs = 0 },
    };
    try std.testing.expectEqual(@as(i64, 1), h.id.raw());
    try std.testing.expectEqual(@as(i64, 42), h.task_id.raw());
    try std.testing.expectEqualStrings("checkpoint", h.body);
}
