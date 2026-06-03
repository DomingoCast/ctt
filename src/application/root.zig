pub const TaskView    = @import("use_cases/task_view.zig").TaskView;
pub const AddTodo     = @import("use_cases/add_todo.zig").AddTodo;
pub const AddTodoInput= @import("use_cases/add_todo.zig").AddTodoInput;
pub const ListTasks   = @import("use_cases/list_tasks.zig").ListTasks;
pub const GetTask     = @import("use_cases/get_task.zig").GetTask;
pub const UpdateTask  = @import("use_cases/update_task.zig").UpdateTask;
pub const ArchiveTask = @import("use_cases/archive_task.zig").ArchiveTask;
pub const DeleteTask  = @import("use_cases/delete_task.zig").DeleteTask;
pub const LinkTask    = @import("use_cases/link_task.zig").LinkTask;
pub const LinkTarget  = @import("use_cases/link_task.zig").LinkTarget;
pub const RefreshAll  = @import("use_cases/refresh_all.zig").RefreshAll;
pub const RefreshReport = @import("use_cases/refresh_all.zig").RefreshReport;
pub const SetSessionHandle = @import("use_cases/set_session_handle.zig").SetSessionHandle;
pub const AddHandoff  = @import("use_cases/add_handoff.zig").AddHandoff;

test {
    _ = @import("use_cases/add_todo.zig");
    _ = @import("use_cases/list_tasks.zig");
    _ = @import("use_cases/get_task.zig");
    _ = @import("use_cases/update_task.zig");
    _ = @import("use_cases/archive_task.zig");
    _ = @import("use_cases/delete_task.zig");
    _ = @import("use_cases/link_task.zig");
    _ = @import("use_cases/refresh_all.zig");
    _ = @import("tests/refresh_all_test.zig");
    _ = @import("use_cases/set_session_handle.zig");
    _ = @import("use_cases/add_handoff.zig");
}
