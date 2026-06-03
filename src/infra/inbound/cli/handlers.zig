const std = @import("std");
const app = @import("application");
const d = @import("domain");
const args_mod = @import("args.zig");
const UseCases = @import("use_cases.zig").UseCases;

// ---------------------------------------------------------------------------
// Public dispatch entry point
// ---------------------------------------------------------------------------

pub fn dispatch(
    a: std.mem.Allocator,
    uc: *UseCases,
    cmd: args_mod.Command,
    writer: anytype,
) !void {
    switch (cmd) {
        .none, .mcp => return, // handled by main.zig
        .list => |args| try handleList(a, uc, args, writer),
        .show => |args| try handleShow(a, uc, args, writer),
        .add => |args| try handleAdd(a, uc, args, writer),
        .update => |args| try handleUpdate(a, uc, args, writer),
        .link => |args| try handleLink(a, uc, args, writer),
        .unlink => |args| try handleUnlink(a, uc, args, writer),
        .archive => |args| try handleArchive(a, uc, args, writer),
        .delete => |args| try handleDelete(a, uc, args, writer),
        .refresh => try handleRefresh(a, uc, writer),
        .open => |args| try handleOpen(a, uc, args, writer),
        .config => |args| try handleConfig(a, uc, args, writer),
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn handleAdd(a: std.mem.Allocator, uc: *UseCases, args: args_mod.AddArgs, writer: anytype) !void {
    const branch_name = if (args.branch) |b| d.BranchName.init(b) else null;
    const t = try uc.add_todo.execute(a, .{
        .title = args.title,
        .branch_hint = branch_name,
    });
    try writer.print("created task #{d}: {s}\n", .{ t.id.raw(), t.title });
}

fn handleList(a: std.mem.Allocator, uc: *UseCases, args: args_mod.ListArgs, writer: anytype) !void {
    var filter: d.TaskFilter = .{};
    if (args.repo) |r| filter.repo_name = r;
    if (args.status) |s| filter.status = parseStatus(s);

    const views = try uc.list_tasks.execute(a, filter);
    defer a.free(views);

    if (args.json) {
        try renderJson(views, writer);
    } else {
        try renderTable(views, writer);
    }
}

fn parseStatus(s: []const u8) ?d.Status {
    if (std.mem.eql(u8, s, "todo")) return .todo;
    if (std.mem.eql(u8, s, "in-progress")) return .in_progress;
    if (std.mem.eql(u8, s, "in-review")) return .in_review;
    if (std.mem.eql(u8, s, "done")) return .done;
    if (std.mem.eql(u8, s, "archived")) return .archived;
    return null;
}

fn renderTable(views: []const app.TaskView, writer: anytype) !void {
    for (views) |v| {
        const status_str = @tagName(v.status);
        try writer.print("#{d}\t[{s}]\t{s}\n", .{ v.task.id.raw(), status_str, v.task.title });
    }
}

fn renderJson(views: []const app.TaskView, writer: anytype) !void {
    try writer.writeAll("[");
    for (views, 0..) |v, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("{{\"id\":{d},\"title\":", .{v.task.id.raw()});
        try writeJsonString(writer, v.task.title);
        try writer.print(",\"status\":\"{s}\",\"archived\":{}}}", .{ @tagName(v.status), v.task.archived });
    }
    try writer.writeAll("]\n");
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn handleShow(a: std.mem.Allocator, uc: *UseCases, args: args_mod.ShowArgs, writer: anytype) !void {
    const view = (try uc.get_task.execute(a, @enumFromInt(args.id))) orelse {
        try writer.print("no task #{d}\n", .{args.id});
        return;
    };
    if (args.json) {
        try renderJson(&[_]app.TaskView{view}, writer);
    } else {
        try writer.print("#{d}\t[{s}]\t{s}\n", .{ view.task.id.raw(), @tagName(view.status), view.task.title });
    }
}

fn handleUpdate(a: std.mem.Allocator, uc: *UseCases, args: args_mod.UpdateArgs, writer: anytype) !void {
    var patch: d.TaskPatch = .{};
    if (args.title) |v| patch.title = v;
    if (args.branch_hint) |v| patch.branch_hint = d.BranchName.init(v);
    if (args.notes) |v| patch.notes = v;
    _ = try uc.update_task.execute(a, @enumFromInt(args.id), patch);
    try writer.print("updated task #{d}\n", .{args.id});
}

fn handleArchive(a: std.mem.Allocator, uc: *UseCases, args: args_mod.ArchiveArgs, writer: anytype) !void {
    _ = try uc.archive.execute(a, @enumFromInt(args.id), true);
    try writer.print("archived task #{d}\n", .{args.id});
}

fn handleDelete(a: std.mem.Allocator, uc: *UseCases, args: args_mod.DeleteArgs, writer: anytype) !void {
    _ = a;
    try uc.delete_task.execute(@enumFromInt(args.id));
    try writer.print("deleted task #{d}\n", .{args.id});
}

fn handleRefresh(a: std.mem.Allocator, uc: *UseCases, writer: anytype) !void {
    var report = try uc.refresh.execute(a, uc.repos);
    defer report.deinit(a);
    try writer.print(
        "refresh: tasks_created={d} prs_updated={d} issues_updated={d} errors={d}\n",
        .{ report.tasks_created, report.prs_updated, report.issues_updated, report.errors.items.len },
    );
}

fn handleLink(a: std.mem.Allocator, uc: *UseCases, args: args_mod.LinkArgs, writer: anytype) !void {
    _ = a;
    _ = uc;
    // For v1 the CLI link command requires the caller to know the worktree/pr/issue *id* (i64),
    // which isn't currently exposed via CLI. Print a clear "not yet supported via CLI in v1" stub.
    try writer.print(
        "link: not fully supported via CLI in v1 (id={d}, wt={?s}, pr={?s}, issue={?s})\n",
        .{ args.id, args.worktree, args.pr, args.issue },
    );
}

fn handleUnlink(a: std.mem.Allocator, uc: *UseCases, args: args_mod.UnlinkArgs, writer: anytype) !void {
    var patch: d.TaskPatch = .{};
    switch (args.target) {
        .worktree => patch.worktree_id = @as(?d.ids.WorktreeId, null),
        .pr => patch.pr_id = @as(?d.ids.PrId, null),
        .issue => patch.issue_id = @as(?d.ids.IssueId, null),
    }
    _ = try uc.update_task.execute(a, @enumFromInt(args.id), patch);
    try writer.print("unlinked task #{d} ({s})\n", .{ args.id, @tagName(args.target) });
}

fn handleOpen(a: std.mem.Allocator, uc: *UseCases, args: args_mod.OpenArgs, writer: anytype) !void {
    const view = (try uc.get_task.execute(a, @enumFromInt(args.id))) orelse {
        try writer.print("no task #{d}\n", .{args.id});
        return;
    };
    const url: ?[]const u8 = if (args.pr)
        (if (view.task.pr) |pr| pr.url.value else null)
    else if (args.issue)
        (if (view.task.issue) |iss| iss.url else null)
    else
        null;
    if (url) |u| {
        try writer.print("{s}\n", .{u});
        // Caller is expected to pipe to `open` / `xdg-open`; spawning a browser is out of scope here.
    } else {
        try writer.print("no url for task #{d}\n", .{args.id});
    }
}

fn handleConfig(a: std.mem.Allocator, uc: *UseCases, args: args_mod.ConfigCmd, writer: anytype) !void {
    _ = a;
    _ = uc;
    // Config mutations are deferred to v1.1; for v1 print informative messages.
    switch (args) {
        .repo_add => |x| try writer.print("config repo add not yet implemented (path={s})\n", .{x.path}),
        .repo_list => try writer.print("config repo list not yet implemented (read config.json directly)\n", .{}),
        .repo_remove => |x| try writer.print("config repo remove not yet implemented (name={s})\n", .{x.name}),
        .linear_set_token => try writer.print("config linear set-token not yet implemented (set CTT_LINEAR_TOKEN or edit secrets.json)\n", .{}),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Handler tests use a module-local mini-fake TaskRepository.
// The application test double (fake_task_repo.zig) lives outside the infra_cli
// module path and cannot be imported directly. A local mini-fake is simpler and
// avoids restructuring the build graph. End-to-end CLI validation is covered by
// the smoke test in Task 9.2.

const MiniRepo = struct {
    arena: std.heap.ArenaAllocator,
    next_id: i64 = 1,
    tasks: std.AutoHashMap(i64, d.Task),

    fn init(a: std.mem.Allocator) MiniRepo {
        return .{
            .arena = std.heap.ArenaAllocator.init(a),
            .tasks = std.AutoHashMap(i64, d.Task).init(a),
        };
    }

    fn deinit(self: *MiniRepo) void {
        self.tasks.deinit();
        self.arena.deinit();
    }

    fn interface(self: *MiniRepo) d.ports.TaskRepository {
        return .{ .ptr = self, .vtable = &mini_vt };
    }

    const mini_vt = d.ports.TaskRepository.VTable{
        .create = miniCreate,
        .get = miniGet,
        .list = miniList,
        .update = miniUpdate,
        .delete = miniDelete,
        .find_by_branch_hint = miniFindByBranchHint,
        .find_by_worktree = miniFindByWorktree,
        .upsert_worktree = miniUpsertWorktree,
        .upsert_pr = miniUpsertPr,
        .upsert_issue = miniUpsertIssue,
    };

    fn miniCreate(p: *anyopaque, _: std.mem.Allocator, draft: d.NewTask) d.ports.TaskRepository.Error!d.Task {
        const self: *MiniRepo = @ptrCast(@alignCast(p));
        const aa = self.arena.allocator();
        const id_val = self.next_id;
        self.next_id += 1;
        const t = d.Task{
            .id = @enumFromInt(id_val),
            .title = aa.dupe(u8, draft.title) catch return error.OutOfMemory,
            .branch_hint = draft.branch_hint,
            .worktree = null,
            .pr = null,
            .issue = null,
            .archived = false,
            .notes = null,
            .session = null,
            .created_at = .{ .unix_secs = 0 },
            .updated_at = .{ .unix_secs = 0 },
        };
        self.tasks.put(id_val, t) catch return error.OutOfMemory;
        return t;
    }

    fn miniGet(p: *anyopaque, _: std.mem.Allocator, id: d.ids.TaskId) d.ports.TaskRepository.Error!?d.Task {
        const self: *MiniRepo = @ptrCast(@alignCast(p));
        return self.tasks.get(id.raw());
    }

    fn miniList(p: *anyopaque, a: std.mem.Allocator, _: d.TaskFilter) d.ports.TaskRepository.Error![]d.Task {
        const self: *MiniRepo = @ptrCast(@alignCast(p));
        var out = a.alloc(d.Task, self.tasks.count()) catch return error.OutOfMemory;
        var it = self.tasks.valueIterator();
        var i: usize = 0;
        while (it.next()) |t| : (i += 1) out[i] = t.*;
        return out;
    }

    fn miniUpdate(p: *anyopaque, _: std.mem.Allocator, id: d.ids.TaskId, patch: d.TaskPatch) d.ports.TaskRepository.Error!d.Task {
        const self: *MiniRepo = @ptrCast(@alignCast(p));
        const existing = self.tasks.getPtr(id.raw()) orelse return error.NotFound;
        if (patch.title) |v| existing.title = v;
        if (patch.archived) |v| existing.archived = v;
        return existing.*;
    }

    fn miniDelete(p: *anyopaque, id: d.ids.TaskId) d.ports.TaskRepository.Error!void {
        const self: *MiniRepo = @ptrCast(@alignCast(p));
        _ = self.tasks.remove(id.raw());
    }

    fn miniFindByBranchHint(_: *anyopaque, _: std.mem.Allocator, _: d.BranchName) d.ports.TaskRepository.Error!?d.Task {
        return null;
    }
    fn miniFindByWorktree(_: *anyopaque, _: std.mem.Allocator, _: d.ids.WorktreeId) d.ports.TaskRepository.Error!?d.Task {
        return null;
    }
    fn miniUpsertWorktree(_: *anyopaque, _: std.mem.Allocator, _: d.ids.RepoId, _: d.WorktreeSnapshot) d.ports.TaskRepository.Error!d.ids.WorktreeId {
        return error.NotFound;
    }
    fn miniUpsertPr(_: *anyopaque, _: std.mem.Allocator, _: d.ids.RepoId, _: d.PrSnapshot, _: d.Timestamp) d.ports.TaskRepository.Error!d.ids.PrId {
        return error.NotFound;
    }
    fn miniUpsertIssue(_: *anyopaque, _: std.mem.Allocator, _: d.ids.ProviderId, _: d.IssueSnapshot, _: d.Timestamp) d.ports.TaskRepository.Error!d.ids.IssueId {
        return error.NotFound;
    }
};

fn buildTestUc(repo: *MiniRepo) UseCases {
    return UseCases{
        .add_todo = .{ .tasks = repo.interface() },
        .list_tasks = .{ .tasks = repo.interface() },
        .get_task = .{ .tasks = repo.interface() },
        .update_task = .{ .tasks = repo.interface() },
        .archive = .{ .tasks = repo.interface() },
        .delete_task = .{ .tasks = repo.interface() },
        .link = .{ .tasks = repo.interface() },
        .refresh = undefined,
        .repos = &.{},
    };
}

test "handleAdd prints created task line" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var uc = buildTestUc(&fake);

    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();

    try handleAdd(a, &uc, .{ .title = "hello world", .branch = null, .issue = null }, &w.writer);

    try std.testing.expectEqualStrings("created task #1: hello world\n", w.writer.buffered());
}

test "handleList renders table output" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();

    // Pre-populate a task via the interface
    _ = try fake.interface().create(a, .{ .title = "my task" });

    var uc = buildTestUc(&fake);

    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();

    try handleList(a, &uc, .{ .json = false }, &w.writer);

    const out = w.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "my task") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#1") != null);
}

test "handleShow prints no task message for missing id" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var uc = buildTestUc(&fake);

    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();

    try handleShow(a, &uc, .{ .id = 999, .json = false }, &w.writer);

    try std.testing.expectEqualStrings("no task #999\n", w.writer.buffered());
}

test "renderJson escapes quotes, backslashes, and control chars" {
    const a = std.testing.allocator;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();

    const view = app.TaskView{
        .task = .{
            .id = @enumFromInt(1),
            .title = "say \"hi\"\nC:\\path\there",
            .branch_hint = null,
            .worktree = null,
            .pr = null,
            .issue = null,
            .archived = false,
            .notes = null,
            .session = null,
            .created_at = .{ .unix_secs = 0 },
            .updated_at = .{ .unix_secs = 0 },
        },
        .status = .todo,
    };

    try renderJson(&[_]app.TaskView{view}, &w.writer);

    // Parse the rendered JSON to verify it's valid and the title round-trips.
    const parsed = try std.json.parseFromSlice(std.json.Value, a, w.writer.buffered(), .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    try std.testing.expectEqual(@as(usize, 1), arr.items.len);
    const title = arr.items[0].object.get("title").?.string;
    try std.testing.expectEqualStrings("say \"hi\"\nC:\\path\there", title);
}
