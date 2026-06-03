const app = @import("application");
const d = @import("domain");

pub const UseCases = struct {
    add_todo: app.AddTodo,
    list_tasks: app.ListTasks,
    get_task: app.GetTask,
    update_task: app.UpdateTask,
    archive: app.ArchiveTask,
    delete_task: app.DeleteTask,
    link: app.LinkTask,
    refresh: app.RefreshAll,
    repos: []const d.Repo, // composition root injects these from config
    set_session: app.SetSessionHandle,
    add_handoff: app.AddHandoff,
    list_handoffs: app.ListHandoffs,
    get_context: app.GetContext,
};
