const std = @import("std");
const d = @import("domain");
const app = @import("application");
const jsonrpc = @import("jsonrpc.zig");
const UseCases = @import("use_cases.zig").UseCases;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Run the MCP JSON-RPC server loop, reading requests from `reader` and
/// writing responses to `writer` until EOF.
pub fn serve(
    a: std.mem.Allocator,
    uc: *UseCases,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    while (true) {
        const parsed = (try jsonrpc.readRequest(a, reader)) orelse break;
        defer parsed.deinit();

        const req = parsed.value;
        // Notifications have no id; use null for the response id.
        const id: std.json.Value = req.id orelse .null;

        if (std.mem.eql(u8, req.method, "initialize")) {
            try writeInitialize(writer, id);
        } else if (std.mem.eql(u8, req.method, "notifications/initialized")) {
            // Client notification – no response needed.
        } else if (std.mem.eql(u8, req.method, "tools/list")) {
            try writeToolsList(writer, id);
        } else if (std.mem.eql(u8, req.method, "tools/call")) {
            try handleToolsCall(a, uc, writer, id, req.params);
        } else {
            try jsonrpc.writeError(writer, id, -32601, "method not found");
        }
    }
}

// ---------------------------------------------------------------------------
// Protocol-level response helpers
// ---------------------------------------------------------------------------

fn writeInitialize(writer: *std.Io.Writer, id: std.json.Value) !void {
    const result =
        \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"ctt","version":"0.1.0"}}
    ;
    try jsonrpc.writeResponse(writer, id, result);
}

fn writeToolsList(writer: *std.Io.Writer, id: std.json.Value) !void {
    // Keep the literal compact (no embedded newlines) so it can be embedded as
    // a raw string.  Newline-separated multi-line strings in Zig multiline
    // literals would include the literal whitespace in the JSON output.
    const result =
        "{\"tools\":[" ++
        "{\"name\":\"ctt_list_tasks\",\"description\":\"List tasks with optional filters\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"status\":{\"type\":\"string\"},\"repo\":{\"type\":\"string\"}}}}," ++
        "{\"name\":\"ctt_get_task\",\"description\":\"Get a single task by ID\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\"}}}}," ++
        "{\"name\":\"ctt_add_todo\",\"description\":\"Create a new todo task\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"title\"],\"properties\":{\"title\":{\"type\":\"string\"},\"branch_hint\":{\"type\":\"string\"}}}}," ++
        "{\"name\":\"ctt_update_task\",\"description\":\"Update fields of an existing task\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\"},\"title\":{\"type\":\"string\"},\"branch_hint\":{\"type\":\"string\"},\"notes\":{\"type\":\"string\"}}}}," ++
        "{\"name\":\"ctt_archive_task\",\"description\":\"Archive or unarchive a task\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"id\",\"archived\"],\"properties\":{\"id\":{\"type\":\"integer\"},\"archived\":{\"type\":\"boolean\"}}}}," ++
        "{\"name\":\"ctt_delete_task\",\"description\":\"Permanently delete a task\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"integer\"}}}}," ++
        "{\"name\":\"ctt_refresh\",\"description\":\"Refresh all tasks from git/GitHub/Linear\",\"inputSchema\":{\"type\":\"object\"}}," ++
        "{\"name\":\"ctt_set_session_handle\",\"description\":\"Associate an LLM session id with a task. Resuming the task later (`ctt resume`) will use this handle.\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"task_id\",\"provider\",\"session_id\"],\"properties\":{\"task_id\":{\"type\":\"integer\"},\"provider\":{\"type\":\"string\"},\"session_id\":{\"type\":\"string\"}}}}," ++
        "{\"name\":\"ctt_clear_session_handle\",\"description\":\"Remove the session handle from a task.\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"task_id\"],\"properties\":{\"task_id\":{\"type\":\"integer\"}}}}," ++
        "{\"name\":\"ctt_add_handoff\",\"description\":\"Append a handoff note to a task's handoff log. Use this to leave context for the next session picking up this task.\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"task_id\",\"body\"],\"properties\":{\"task_id\":{\"type\":\"integer\"},\"body\":{\"type\":\"string\"}}}}," ++
        "{\"name\":\"ctt_list_handoffs\",\"description\":\"Return the task's handoff log entries, newest first. Optional limit.\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"task_id\"],\"properties\":{\"task_id\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}}}}," ++
        "{\"name\":\"ctt_get_context\",\"description\":\"Return everything needed to resume a task: task fields, session handle, links, and handoff log. Use this when picking up a task in a fresh session.\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"task_id\"],\"properties\":{\"task_id\":{\"type\":\"integer\"},\"handoff_limit\":{\"type\":\"integer\"}}}}" ++
        "]}";
    try jsonrpc.writeResponse(writer, id, result);
}

// ---------------------------------------------------------------------------
// tools/call dispatch
// ---------------------------------------------------------------------------

fn handleToolsCall(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    params_opt: ?std.json.Value,
) !void {
    const params = params_opt orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing params");
        return;
    };
    if (params != .object) {
        try jsonrpc.writeError(writer, id, -32602, "params must be object");
        return;
    }

    const name_val = params.object.get("name") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing tool name");
        return;
    };
    if (name_val != .string) {
        try jsonrpc.writeError(writer, id, -32602, "tool name must be string");
        return;
    }
    const name = name_val.string;

    // `arguments` is optional; default to an empty object.
    const empty_obj = std.json.Value{ .object = .empty };
    const args = params.object.get("arguments") orelse empty_obj;

    if (std.mem.eql(u8, name, "ctt_list_tasks")) {
        try toolListTasks(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_get_task")) {
        try toolGetTask(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_add_todo")) {
        try toolAddTodo(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_update_task")) {
        try toolUpdate(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_archive_task")) {
        try toolArchive(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_delete_task")) {
        try toolDelete(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_refresh")) {
        try toolRefresh(a, uc, writer, id);
    } else if (std.mem.eql(u8, name, "ctt_set_session_handle")) {
        try toolSetSessionHandle(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_clear_session_handle")) {
        try toolClearSessionHandle(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_add_handoff")) {
        try toolAddHandoff(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_list_handoffs")) {
        try toolListHandoffs(a, uc, writer, id, args);
    } else if (std.mem.eql(u8, name, "ctt_get_context")) {
        try toolGetContext(a, uc, writer, id, args);
    } else {
        try jsonrpc.writeError(writer, id, -32601, "unknown tool");
    }
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------

fn toolListTasks(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }

    var filter: d.TaskFilter = .{};
    if (args.object.get("status")) |sv| {
        if (sv == .string) filter.status = parseStatus(sv.string);
    }
    if (args.object.get("repo")) |rv| {
        if (rv == .string) filter.repo_name = rv.string;
    }

    const views = try uc.list_tasks.execute(a, filter);
    defer a.free(views);

    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try renderTaskViewsJson(views, &buf.writer);

    const json_str = buf.writer.buffered();
    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();
    try result_buf.writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try jsonrpc.writeJsonString(&result_buf.writer, json_str);
    try result_buf.writer.writeAll("}]}");

    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

fn toolGetTask(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const id_val = args.object.get("id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing id");
        return;
    };
    if (id_val != .integer) {
        try jsonrpc.writeError(writer, id, -32602, "id must be integer");
        return;
    }

    const task_id: d.ids.TaskId = @enumFromInt(id_val.integer);
    const view_opt = try uc.get_task.execute(a, task_id);

    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();

    if (view_opt) |view| {
        var task_json_buf: std.Io.Writer.Allocating = .init(a);
        defer task_json_buf.deinit();
        try renderTaskViewJson(view, &task_json_buf.writer);

        try result_buf.writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try jsonrpc.writeJsonString(&result_buf.writer, task_json_buf.writer.buffered());
        try result_buf.writer.writeAll("}]}");
    } else {
        try result_buf.writer.print(
            "{{\"content\":[{{\"type\":\"text\",\"text\":\"no task #{d}\"}}]}}",
            .{id_val.integer},
        );
    }

    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

fn toolAddTodo(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const title_val = args.object.get("title") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing title");
        return;
    };
    if (title_val != .string) {
        try jsonrpc.writeError(writer, id, -32602, "title must be string");
        return;
    }

    const branch_hint: ?d.BranchName = if (args.object.get("branch_hint")) |bv|
        (if (bv == .string) d.BranchName.init(bv.string) else null)
    else
        null;

    const task = try uc.add_todo.execute(a, .{
        .title = title_val.string,
        .branch_hint = branch_hint,
    });

    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();
    try result_buf.writer.print(
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"task #{d} created\"}}]}}",
        .{task.id.raw()},
    );
    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

fn toolUpdate(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const id_val = args.object.get("id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing id");
        return;
    };
    if (id_val != .integer) {
        try jsonrpc.writeError(writer, id, -32602, "id must be integer");
        return;
    }

    var patch: d.TaskPatch = .{};
    if (args.object.get("title")) |v| {
        if (v == .string) patch.title = v.string;
    }
    if (args.object.get("branch_hint")) |v| {
        if (v == .string) patch.branch_hint = d.BranchName.init(v.string);
    }
    if (args.object.get("notes")) |v| {
        if (v == .string) patch.notes = v.string;
    }

    const task_id: d.ids.TaskId = @enumFromInt(id_val.integer);
    _ = try uc.update_task.execute(a, task_id, patch);

    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();
    try result_buf.writer.print(
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"task #{d} updated\"}}]}}",
        .{id_val.integer},
    );
    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

fn toolArchive(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const id_val = args.object.get("id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing id");
        return;
    };
    if (id_val != .integer) {
        try jsonrpc.writeError(writer, id, -32602, "id must be integer");
        return;
    }
    const archived_val = args.object.get("archived") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing archived");
        return;
    };
    if (archived_val != .bool) {
        try jsonrpc.writeError(writer, id, -32602, "archived must be boolean");
        return;
    }

    const task_id: d.ids.TaskId = @enumFromInt(id_val.integer);
    _ = try uc.archive.execute(a, task_id, archived_val.bool);

    const action = if (archived_val.bool) "archived" else "unarchived";
    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();
    try result_buf.writer.print(
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"task #{d} {s}\"}}]}}",
        .{ id_val.integer, action },
    );
    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

fn toolDelete(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const id_val = args.object.get("id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing id");
        return;
    };
    if (id_val != .integer) {
        try jsonrpc.writeError(writer, id, -32602, "id must be integer");
        return;
    }

    const task_id: d.ids.TaskId = @enumFromInt(id_val.integer);
    try uc.delete_task.execute(task_id);

    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();
    try result_buf.writer.print(
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"task #{d} deleted\"}}]}}",
        .{id_val.integer},
    );
    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

fn toolRefresh(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
) !void {
    var report = try uc.refresh.execute(a, uc.repos);
    defer report.deinit(a);

    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();
    try result_buf.writer.print(
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"refresh: tasks_created={d} prs_updated={d} issues_updated={d} errors={d}\"}}]}}",
        .{ report.tasks_created, report.prs_updated, report.issues_updated, report.errors.items.len },
    );
    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

fn toolSetSessionHandle(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const task_id_val = args.object.get("task_id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing task_id");
        return;
    };
    if (task_id_val != .integer) {
        try jsonrpc.writeError(writer, id, -32602, "task_id must be integer");
        return;
    }
    const provider_val = args.object.get("provider") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing provider");
        return;
    };
    if (provider_val != .string) {
        try jsonrpc.writeError(writer, id, -32602, "provider must be string");
        return;
    }
    const session_id_val = args.object.get("session_id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing session_id");
        return;
    };
    if (session_id_val != .string) {
        try jsonrpc.writeError(writer, id, -32602, "session_id must be string");
        return;
    }

    const task_id: d.ids.TaskId = @enumFromInt(task_id_val.integer);
    _ = try uc.set_session.execute(a, task_id, .{
        .provider = provider_val.string,
        .session_id = session_id_val.string,
    });

    try jsonrpc.writeResponse(writer, id, "{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":true}\"}]}");
}

fn toolClearSessionHandle(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const task_id_val = args.object.get("task_id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing task_id");
        return;
    };
    if (task_id_val != .integer) {
        try jsonrpc.writeError(writer, id, -32602, "task_id must be integer");
        return;
    }

    const task_id: d.ids.TaskId = @enumFromInt(task_id_val.integer);
    _ = try uc.set_session.execute(a, task_id, null);

    try jsonrpc.writeResponse(writer, id, "{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":true}\"}]}");
}

fn toolAddHandoff(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const task_id_val = args.object.get("task_id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing task_id");
        return;
    };
    if (task_id_val != .integer) {
        try jsonrpc.writeError(writer, id, -32602, "task_id must be integer");
        return;
    }
    const body_val = args.object.get("body") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing body");
        return;
    };
    if (body_val != .string) {
        try jsonrpc.writeError(writer, id, -32602, "body must be string");
        return;
    }

    const task_id: d.ids.TaskId = @enumFromInt(task_id_val.integer);
    const handoff_id = try uc.add_handoff.execute(a, task_id, body_val.string);

    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();
    try result_buf.writer.print(
        "{{\"content\":[{{\"type\":\"text\",\"text\":\"{{\\\"handoff_id\\\":{d}}}\"}}]}}",
        .{handoff_id.raw()},
    );
    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

fn toolListHandoffs(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const task_id_val = args.object.get("task_id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing task_id");
        return;
    };
    if (task_id_val != .integer) {
        try jsonrpc.writeError(writer, id, -32602, "task_id must be integer");
        return;
    }

    const limit: ?usize = if (args.object.get("limit")) |lv|
        (if (lv == .integer and lv.integer > 0) @intCast(lv.integer) else null)
    else
        null;

    const task_id: d.ids.TaskId = @enumFromInt(task_id_val.integer);
    const entries = try uc.list_handoffs.execute(a, task_id, limit);
    defer {
        for (entries) |e| a.free(e.body);
        a.free(entries);
    }

    var entries_buf: std.Io.Writer.Allocating = .init(a);
    defer entries_buf.deinit();
    try renderHandoffEntriesJson(entries, &entries_buf.writer);

    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();
    try result_buf.writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try jsonrpc.writeJsonString(&result_buf.writer, entries_buf.writer.buffered());
    try result_buf.writer.writeAll("}]}");

    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

fn toolGetContext(
    a: std.mem.Allocator,
    uc: *UseCases,
    writer: *std.Io.Writer,
    id: std.json.Value,
    args: std.json.Value,
) !void {
    if (args != .object) {
        try jsonrpc.writeError(writer, id, -32602, "arguments must be object");
        return;
    }
    const task_id_val = args.object.get("task_id") orelse {
        try jsonrpc.writeError(writer, id, -32602, "missing task_id");
        return;
    };
    if (task_id_val != .integer) {
        try jsonrpc.writeError(writer, id, -32602, "task_id must be integer");
        return;
    }

    const handoff_limit: ?usize = if (args.object.get("handoff_limit")) |lv|
        (if (lv == .integer and lv.integer > 0) @intCast(lv.integer) else null)
    else
        null;

    const task_id: d.ids.TaskId = @enumFromInt(task_id_val.integer);
    const maybe_ctx = try uc.get_context.execute(a, task_id, handoff_limit);

    var result_buf: std.Io.Writer.Allocating = .init(a);
    defer result_buf.deinit();

    if (maybe_ctx) |ctx| {
        defer {
            for (ctx.handoffs) |e| a.free(e.body);
            a.free(ctx.handoffs);
            @import("application").freeTask(a, ctx.task);
        }

        var ctx_buf: std.Io.Writer.Allocating = .init(a);
        defer ctx_buf.deinit();
        try renderContextJson(ctx, &ctx_buf.writer);

        try result_buf.writer.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try jsonrpc.writeJsonString(&result_buf.writer, ctx_buf.writer.buffered());
        try result_buf.writer.writeAll("}]}");
    } else {
        try result_buf.writer.print(
            "{{\"content\":[{{\"type\":\"text\",\"text\":\"no task #{d}\"}}]}}",
            .{task_id_val.integer},
        );
    }

    try jsonrpc.writeResponse(writer, id, result_buf.writer.buffered());
}

// ---------------------------------------------------------------------------
// JSON rendering helpers
// ---------------------------------------------------------------------------

fn parseStatus(s: []const u8) ?d.Status {
    if (std.mem.eql(u8, s, "todo")) return .todo;
    if (std.mem.eql(u8, s, "in-progress")) return .in_progress;
    if (std.mem.eql(u8, s, "in-review")) return .in_review;
    if (std.mem.eql(u8, s, "done")) return .done;
    if (std.mem.eql(u8, s, "archived")) return .archived;
    return null;
}

fn renderTaskViewsJson(views: []const app.TaskView, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    for (views, 0..) |v, i| {
        if (i > 0) try writer.writeByte(',');
        try renderTaskViewJson(v, writer);
    }
    try writer.writeByte(']');
}

fn renderTaskViewJson(v: app.TaskView, writer: *std.Io.Writer) !void {
    try writer.print("{{\"id\":{d},\"title\":", .{v.task.id.raw()});
    try jsonrpc.writeJsonString(writer, v.task.title);
    try writer.print(",\"status\":\"{s}\",\"archived\":{}", .{ @tagName(v.status), v.task.archived });
    if (v.task.notes) |n| {
        try writer.writeAll(",\"notes\":");
        try jsonrpc.writeJsonString(writer, n);
    }
    if (v.task.branch_hint) |b| {
        try writer.writeAll(",\"branch_hint\":");
        try jsonrpc.writeJsonString(writer, b.value);
    }
    try writer.writeByte('}');
}

fn renderHandoffEntryJson(e: d.HandoffEntry, writer: *std.Io.Writer) !void {
    try writer.print("{{\"id\":{d},\"task_id\":{d},\"created_at\":{d},\"body\":", .{
        e.id.raw(), e.task_id.raw(), e.created_at.unix_secs,
    });
    try jsonrpc.writeJsonString(writer, e.body);
    try writer.writeByte('}');
}

fn renderHandoffEntriesJson(entries: []const d.HandoffEntry, writer: *std.Io.Writer) !void {
    try writer.writeByte('[');
    for (entries, 0..) |e, i| {
        if (i > 0) try writer.writeByte(',');
        try renderHandoffEntryJson(e, writer);
    }
    try writer.writeByte(']');
}

fn renderTaskJson(t: d.Task, writer: *std.Io.Writer) !void {
    try writer.print("{{\"id\":{d},\"title\":", .{t.id.raw()});
    try jsonrpc.writeJsonString(writer, t.title);
    try writer.print(",\"archived\":{}", .{t.archived});
    if (t.notes) |n| {
        try writer.writeAll(",\"notes\":");
        try jsonrpc.writeJsonString(writer, n);
    }
    if (t.branch_hint) |b| {
        try writer.writeAll(",\"branch_hint\":");
        try jsonrpc.writeJsonString(writer, b.value);
    }
    if (t.session) |s| {
        try writer.writeAll(",\"session\":{\"provider\":");
        try jsonrpc.writeJsonString(writer, s.provider);
        try writer.writeAll(",\"session_id\":");
        try jsonrpc.writeJsonString(writer, s.session_id);
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
}

fn renderContextJson(ctx: app.TaskContext, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"task\":");
    try renderTaskJson(ctx.task, writer);
    try writer.writeAll(",\"handoffs\":");
    try renderHandoffEntriesJson(ctx.handoffs, writer);
    try writer.writeByte('}');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// The MCP server tests use the same mini fake repository pattern as the CLI tests.

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
            .project_path = null,
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
        if (patch.session) |maybe_session| existing.session = maybe_session;
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

/// Minimal in-memory HandoffRepository for tests.
const MiniHandoffRepo = struct {
    arena: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    next_id: i64 = 1,
    entries: std.ArrayList(d.HandoffEntry),

    fn init(a: std.mem.Allocator) MiniHandoffRepo {
        return .{
            .arena = std.heap.ArenaAllocator.init(a),
            .backing = a,
            .entries = .empty,
        };
    }

    fn deinit(self: *MiniHandoffRepo) void {
        self.entries.deinit(self.backing);
        self.arena.deinit();
    }

    fn interface(self: *MiniHandoffRepo) d.ports.HandoffRepository {
        return .{ .ptr = self, .vtable = &mini_hvt };
    }

    const mini_hvt = d.ports.HandoffRepository.VTable{
        .append = miniHAppend,
        .list   = miniHList,
        .latest = miniHLatest,
    };

    fn miniHAppend(p: *anyopaque, _: std.mem.Allocator, draft: d.NewHandoff, now: d.Timestamp) d.ports.HandoffRepository.Error!d.ids.HandoffId {
        const self: *MiniHandoffRepo = @ptrCast(@alignCast(p));
        const aa = self.arena.allocator();
        const id_val = self.next_id;
        self.next_id += 1;
        const e = d.HandoffEntry{
            .id = @enumFromInt(id_val),
            .task_id = draft.task_id,
            .body = aa.dupe(u8, draft.body) catch return error.OutOfMemory,
            .created_at = now,
        };
        self.entries.append(self.backing, e) catch return error.OutOfMemory;
        return e.id;
    }

    fn miniHList(p: *anyopaque, a: std.mem.Allocator, task_id: d.ids.TaskId, limit: ?usize) d.ports.HandoffRepository.Error![]d.HandoffEntry {
        const self: *MiniHandoffRepo = @ptrCast(@alignCast(p));
        var out: std.ArrayList(d.HandoffEntry) = .empty;
        errdefer {
            for (out.items) |e| a.free(e.body);
            out.deinit(a);
        }
        var i = self.entries.items.len;
        var count: usize = 0;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (e.task_id != task_id) continue;
            if (limit) |lim| { if (count >= lim) break; }
            const body_owned = a.dupe(u8, e.body) catch return error.OutOfMemory;
            out.append(a, .{ .id = e.id, .task_id = e.task_id, .body = body_owned, .created_at = e.created_at }) catch {
                a.free(body_owned);
                return error.OutOfMemory;
            };
            count += 1;
        }
        return out.toOwnedSlice(a) catch return error.OutOfMemory;
    }

    fn miniHLatest(_: *anyopaque, _: std.mem.Allocator, _: d.ids.TaskId) d.ports.HandoffRepository.Error!?d.HandoffEntry {
        return null;
    }
};

/// Minimal clock for tests — always returns epoch zero.
const MiniClock = struct {
    var dummy: u8 = 0;
    const vt = d.ports.Clock.VTable{ .now = nowFn };
    fn nowFn(_: *anyopaque) d.Timestamp { return .{ .unix_secs = 0 }; }
    fn iface() d.ports.Clock { return .{ .ptr = &dummy, .vtable = &vt }; }
};

fn buildTestUc(repo: *MiniRepo, hrepo: *MiniHandoffRepo) UseCases {
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
        .set_session = .{ .tasks = repo.interface() },
        .add_handoff = .{ .handoffs = hrepo.interface(), .clock = MiniClock.iface() },
        .list_handoffs = .{ .handoffs = hrepo.interface() },
        .get_context = .{ .tasks = repo.interface(), .handoffs = hrepo.interface() },
    };
}

/// Helper: run MCP server against a string request, return response string.
fn runRequest(
    a: std.mem.Allocator,
    uc: *UseCases,
    request_line: []const u8,
) ![]u8 {
    var reader: std.Io.Reader = .fixed(request_line);
    var w: std.Io.Writer.Allocating = .init(a);
    errdefer w.deinit();
    try serve(a, uc, &reader, &w.writer);
    const out = try a.dupe(u8, w.writer.buffered());
    w.deinit();
    return out;
}

test "server responds to initialize with protocolVersion" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    var uc = buildTestUc(&fake, &fake_h);

    const resp = try runRequest(a, &uc, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n");
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ctt") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "2024-11-05") != null);
}

test "server responds to tools/list with all 12 tools" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    var uc = buildTestUc(&fake, &fake_h);

    const resp = try runRequest(a, &uc, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n");
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "ctt_list_tasks") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ctt_add_todo") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ctt_refresh") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ctt_set_session_handle") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ctt_clear_session_handle") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ctt_add_handoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ctt_list_handoffs") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "ctt_get_context") != null);
}

test "server handles unknown method with -32601 error" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    var uc = buildTestUc(&fake, &fake_h);

    const resp = try runRequest(a, &uc, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"no_such_method\"}\n");
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "method not found") != null);
}

test "server ctt_add_todo creates task and returns id" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    var uc = buildTestUc(&fake, &fake_h);

    const req =
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ctt_add_todo","arguments":{"title":"my task"}}}
        ++ "\n";
    const resp = try runRequest(a, &uc, req);
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "task #1 created") != null);
}

test "server ctt_list_tasks returns task list as text" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    _ = try fake.interface().create(a, .{ .title = "list me" });
    var uc = buildTestUc(&fake, &fake_h);

    const req =
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ctt_list_tasks","arguments":{}}}
        ++ "\n";
    const resp = try runRequest(a, &uc, req);
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "list me") != null);
}

test "server ctt_delete_task removes task" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    _ = try fake.interface().create(a, .{ .title = "to delete" });
    var uc = buildTestUc(&fake, &fake_h);

    const req =
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ctt_delete_task","arguments":{"id":1}}}
        ++ "\n";
    const resp = try runRequest(a, &uc, req);
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "task #1 deleted") != null);
}

test "server ctt_get_task returns not found message" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    var uc = buildTestUc(&fake, &fake_h);

    const req =
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ctt_get_task","arguments":{"id":999}}}
        ++ "\n";
    const resp = try runRequest(a, &uc, req);
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "no task #999") != null);
}

test "server ctt_archive_task archives a task" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    _ = try fake.interface().create(a, .{ .title = "archive me" });
    var uc = buildTestUc(&fake, &fake_h);

    const req =
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"ctt_archive_task","arguments":{"id":1,"archived":true}}}
        ++ "\n";
    const resp = try runRequest(a, &uc, req);
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "task #1 archived") != null);
}

test "server ctt_update_task updates title" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    _ = try fake.interface().create(a, .{ .title = "old title" });
    var uc = buildTestUc(&fake, &fake_h);

    const req =
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"ctt_update_task","arguments":{"id":1,"title":"new title"}}}
        ++ "\n";
    const resp = try runRequest(a, &uc, req);
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "task #1 updated") != null);
}

test "server ctt_add_handoff returns handoff_id" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    _ = try fake.interface().create(a, .{ .title = "a task" });
    var uc = buildTestUc(&fake, &fake_h);

    const req =
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"ctt_add_handoff","arguments":{"task_id":1,"body":"checkpoint note"}}}
        ++ "\n";
    const resp = try runRequest(a, &uc, req);
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "handoff_id") != null);
}

test "server ctt_list_handoffs returns entries" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    _ = try fake.interface().create(a, .{ .title = "a task" });
    const task_id: d.ids.TaskId = @enumFromInt(1);
    _ = try fake_h.interface().append(a, .{ .task_id = task_id, .body = "note one" }, .{ .unix_secs = 0 });
    var uc = buildTestUc(&fake, &fake_h);

    const req =
        \\{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"ctt_list_handoffs","arguments":{"task_id":1}}}
        ++ "\n";
    const resp = try runRequest(a, &uc, req);
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "note one") != null);
}

test "server ctt_get_context returns null for missing task" {
    const a = std.testing.allocator;
    var fake = MiniRepo.init(a);
    defer fake.deinit();
    var fake_h = MiniHandoffRepo.init(a);
    defer fake_h.deinit();
    var uc = buildTestUc(&fake, &fake_h);

    const req =
        \\{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"ctt_get_context","arguments":{"task_id":99}}}
        ++ "\n";
    const resp = try runRequest(a, &uc, req);
    defer a.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "no task #99") != null);
}
