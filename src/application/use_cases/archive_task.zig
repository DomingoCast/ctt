const std = @import("std");
const d = @import("domain");

pub const ArchiveTask = struct {
    tasks: d.ports.TaskRepository,
    pub fn execute(self: ArchiveTask, a: std.mem.Allocator, id: d.ids.TaskId, archived: bool) !d.Task {
        return self.tasks.update(a, id, .{ .archived = archived });
    }
};
