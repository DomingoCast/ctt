const std = @import("std");
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
    add_handoff: app.AddHandoff,
    get_context: app.GetContext,
    // For BuildResumeCommand: composition root wires these from config.
    templates_lookup: *const fn (provider: []const u8) ?app.BuildResumeCommand.ProviderTemplate,
    default_provider: ?[]const u8,
    spawn_template: ?[]const u8,
    // Needed for interactive process spawning and absolute-path file writes.
    io: std.Io,
};
