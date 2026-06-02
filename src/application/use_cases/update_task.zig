const std = @import("std");
const d = @import("domain");

pub const UpdateTask = struct {
    tasks: d.ports.TaskRepository,
    pub fn execute(self: UpdateTask, a: std.mem.Allocator, id: d.ids.TaskId, p: d.TaskPatch) !d.Task {
        return self.tasks.update(a, id, p);
    }
};
