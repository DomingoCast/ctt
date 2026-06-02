const std = @import("std");
const d = @import("domain");
const TaskView = @import("task_view.zig").TaskView;

pub const ListTasks = struct {
    tasks: d.ports.TaskRepository,

    pub fn execute(self: ListTasks, a: std.mem.Allocator, filter: d.TaskFilter) ![]TaskView {
        const raw = try self.tasks.list(a, filter);
        defer a.free(raw);
        var out = try a.alloc(TaskView, raw.len);
        for (raw, 0..) |t, i| out[i] = TaskView.from(t);
        return out;
    }
};
