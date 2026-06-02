const d = @import("domain");

pub const DeleteTask = struct {
    tasks: d.ports.TaskRepository,
    pub fn execute(self: DeleteTask, id: d.ids.TaskId) !void {
        return self.tasks.delete(id);
    }
};
