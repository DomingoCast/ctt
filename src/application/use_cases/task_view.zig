const d = @import("domain");

pub const TaskView = struct {
    task: d.Task,
    status: d.Status,

    pub fn from(task: d.Task) TaskView {
        return .{ .task = task, .status = d.derive_status(task) };
    }
};
