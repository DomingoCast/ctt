const std = @import("std");
const d = @import("domain");
const TaskView = @import("task_view.zig").TaskView;

pub const GetTask = struct {
    tasks: d.ports.TaskRepository,
    pub fn execute(self: GetTask, a: std.mem.Allocator, id: d.ids.TaskId) !?TaskView {
        const t = try self.tasks.get(a, id) orelse return null;
        return TaskView.from(t);
    }
};
