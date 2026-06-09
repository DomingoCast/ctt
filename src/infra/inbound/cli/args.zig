const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const Command = union(enum) {
    none, // launch TUI
    help, // print top-level usage
    list: ListArgs,
    show: ShowArgs,
    add: AddArgs,
    update: UpdateArgs,
    link: LinkArgs,
    unlink: UnlinkArgs,
    archive: ArchiveArgs,
    delete: DeleteArgs,
    refresh,
    open: OpenArgs,
    config: ConfigCmd,
    mcp,
    session: SessionArgs,
    handoff: HandoffArgs,
    context: ContextArgs,
    @"resume": ResumeArgs,
};

pub const ListArgs = struct {
    status: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    json: bool = false,
};

pub const ShowArgs = struct {
    id: i64,
    json: bool = false,
};

pub const AddArgs = struct {
    title: []const u8,
    branch: ?[]const u8 = null,
    issue: ?[]const u8 = null,
    project: ?[]const u8 = null,
};

pub const UpdateArgs = struct {
    id: i64,
    title: ?[]const u8 = null,
    branch_hint: ?[]const u8 = null,
    notes: ?[]const u8 = null,
};

pub const LinkArgs = struct {
    id: i64,
    worktree: ?[]const u8 = null,
    pr: ?[]const u8 = null,
    issue: ?[]const u8 = null,
};

pub const UnlinkTarget = enum { worktree, pr, issue };

pub const UnlinkArgs = struct {
    id: i64,
    target: UnlinkTarget,
};

pub const ArchiveArgs = struct { id: i64 };
pub const DeleteArgs = struct { id: i64 };
pub const OpenArgs = struct {
    id: i64,
    pr: bool = false,
    issue: bool = false,
};

pub const ConfigCmd = union(enum) {
    repo_add: struct { path: []const u8 },
    repo_list,
    repo_remove: struct { name: []const u8 },
    linear_set_token: struct { token: []const u8 },
    project_root_add: struct { path: []const u8 },
    project_root_list,
    project_root_remove: struct { path: []const u8 },
};

pub const SessionArgs = union(enum) {
    set: struct { id: i64, provider: []const u8, session_id: []const u8 },
    clear: struct { id: i64 },
};

pub const HandoffArgs = struct {
    id: i64,
    note: ?[]const u8 = null,    // if null and !list and !latest, read body from stdin
    list: bool = false,
    latest: bool = false,
    json: bool = false,
};

pub const ContextArgs = struct {
    id: i64,
    json: bool = false,
    handoff_limit: ?u32 = null,
};

pub const ResumeArgs = struct {
    id: i64,
    print: bool = false,
    fresh: bool = false,
};

pub const ParseError = error{ MissingArg, BadInt, UnknownCommand, ParseFailed, OutOfMemory };

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

/// Parse from actual process args. Skips argv[0] (exe name).
/// `process_args` is `std.process.Args` (provided by the runtime via `std.process.Init`).
pub fn parse(a: std.mem.Allocator, process_args: std.process.Args) ParseError!Command {
    // On POSIX, Args.vector is []const [*:0]const u8.
    const vec = process_args.vector;
    // vec[0] is argv[0] (the exe name); we want everything after that.
    if (vec.len < 2) return .none;
    const rest = vec[1..];
    // Allocate a temporary slice of [:0]u8 that parseFromArgs expects.
    // Each element is a sentinel-terminated mutable slice view over the same memory.
    const sub_args = try a.alloc([:0]u8, rest.len);
    defer a.free(sub_args);
    for (rest, 0..) |ptr, i| {
        // std.mem.span gives us [:0]const u8; we need [:0]u8.
        // The runtime owns this memory for the lifetime of main, so the cast is safe.
        sub_args[i] = @constCast(std.mem.span(ptr));
    }
    return try parseFromArgs(a, sub_args);
}

/// Parse from a caller-supplied slice (used in tests and by `parse`).
pub fn parseFromArgs(a: std.mem.Allocator, args: []const [:0]u8) ParseError!Command {
    if (args.len == 0) return .none;
    const sub = args[0];

    if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) return .help;
    if (std.mem.eql(u8, sub, "list")) return try parseList(a, args[1..]);
    if (std.mem.eql(u8, sub, "show")) return try parseShow(a, args[1..]);
    if (std.mem.eql(u8, sub, "add")) return try parseAdd(a, args[1..]);
    if (std.mem.eql(u8, sub, "update")) return try parseUpdate(a, args[1..]);
    if (std.mem.eql(u8, sub, "link")) return try parseLink(a, args[1..]);
    if (std.mem.eql(u8, sub, "unlink")) return try parseUnlink(a, args[1..]);
    if (std.mem.eql(u8, sub, "archive")) return try parseArchive(a, args[1..]);
    if (std.mem.eql(u8, sub, "delete")) return try parseDelete(a, args[1..]);
    if (std.mem.eql(u8, sub, "refresh")) return .refresh;
    if (std.mem.eql(u8, sub, "open")) return try parseOpen(a, args[1..]);
    if (std.mem.eql(u8, sub, "config")) return try parseConfig(a, args[1..]);
    if (std.mem.eql(u8, sub, "mcp")) return .mcp;
    if (std.mem.eql(u8, sub, "session")) return try parseSession(a, args[1..]);
    if (std.mem.eql(u8, sub, "handoff")) return try parseHandoff(a, args[1..]);
    if (std.mem.eql(u8, sub, "context")) return try parseContext(a, args[1..]);
    if (std.mem.eql(u8, sub, "resume"))  return try parseResume(a, args[1..]);

    return error.UnknownCommand;
}

// ---------------------------------------------------------------------------
// Free allocated strings inside a Command (used in tests to avoid leaks)
// ---------------------------------------------------------------------------

pub fn freeCommand(a: std.mem.Allocator, cmd: Command) void {
    switch (cmd) {
        .none, .help, .refresh, .mcp => {},
        .list => |v| {
            if (v.status) |s| a.free(s);
            if (v.repo) |r| a.free(r);
        },
        .show => {},
        .add => |v| {
            a.free(v.title);
            if (v.branch) |b| a.free(b);
            if (v.issue) |i| a.free(i);
            if (v.project) |p| a.free(p);
        },
        .update => |v| {
            if (v.title) |t| a.free(t);
            if (v.branch_hint) |b| a.free(b);
            if (v.notes) |n| a.free(n);
        },
        .link => |v| {
            if (v.worktree) |w| a.free(w);
            if (v.pr) |p| a.free(p);
            if (v.issue) |i| a.free(i);
        },
        .unlink => {},
        .archive => {},
        .delete => {},
        .open => {},
        .config => |v| {
            switch (v) {
                .repo_add => |c| a.free(c.path),
                .repo_list => {},
                .repo_remove => |c| a.free(c.name),
                .linear_set_token => |c| a.free(c.token),
                .project_root_add => |c| a.free(c.path),
                .project_root_list => {},
                .project_root_remove => |c| a.free(c.path),
            }
        },
        .session => |v| switch (v) {
            .set => |c| { a.free(c.provider); a.free(c.session_id); },
            .clear => {},
        },
        .handoff => |v| if (v.note) |n| a.free(n),
        .context => {},
        .@"resume" => {},
    }
}

// ---------------------------------------------------------------------------
// Sub-parsers (hand-rolled)
// ---------------------------------------------------------------------------

fn parseList(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    var result = ListArgs{};
    errdefer if (result.status) |s| a.free(s);
    errdefer if (result.repo) |r| a.free(r);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.status = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--repo")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.repo = try a.dupe(u8, argv[i]);
        }
        // ignore unknown flags for forward-compat
    }
    return .{ .list = result };
}

fn parseShow(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    _ = a;
    var result = ShowArgs{ .id = 0 };
    var got_id = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .show = result };
}

fn parseAdd(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    var result = AddArgs{ .title = "" };
    var got_title = false;
    errdefer if (result.branch) |b| a.free(b);
    errdefer if (result.issue) |iss| a.free(iss);
    errdefer if (result.project) |p| a.free(p);
    errdefer if (got_title) a.free(result.title);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--branch")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.branch = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--issue")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.issue = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--project")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.project = try a.dupe(u8, argv[i]);
        } else if (!got_title) {
            result.title = try a.dupe(u8, arg);
            got_title = true;
        }
    }
    if (!got_title) return error.MissingArg;
    return .{ .add = result };
}

fn parseUpdate(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    var result = UpdateArgs{ .id = 0 };
    var got_id = false;
    errdefer if (result.title) |t| a.free(t);
    errdefer if (result.branch_hint) |b| a.free(b);
    errdefer if (result.notes) |n| a.free(n);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.title = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--branch-hint")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.branch_hint = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--notes")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.notes = try a.dupe(u8, argv[i]);
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .update = result };
}

fn parseLink(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    var result = LinkArgs{ .id = 0 };
    var got_id = false;
    errdefer if (result.worktree) |w| a.free(w);
    errdefer if (result.pr) |p| a.free(p);
    errdefer if (result.issue) |iss| a.free(iss);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--worktree")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.worktree = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--pr")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.pr = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--issue")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.issue = try a.dupe(u8, argv[i]);
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .link = result };
}

fn parseUnlink(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    _ = a;
    var id: i64 = 0;
    var got_id = false;
    var target_str: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (!got_id) {
            id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        } else if (target_str == null) {
            target_str = arg;
        }
    }
    if (!got_id) return error.MissingArg;
    const tgt_str = target_str orelse return error.MissingArg;
    const target = if (std.mem.eql(u8, tgt_str, "worktree"))
        UnlinkTarget.worktree
    else if (std.mem.eql(u8, tgt_str, "pr"))
        UnlinkTarget.pr
    else if (std.mem.eql(u8, tgt_str, "issue"))
        UnlinkTarget.issue
    else
        return error.UnknownCommand;
    return .{ .unlink = .{ .id = id, .target = target } };
}

fn parseArchive(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    _ = a;
    if (argv.len < 1) return error.MissingArg;
    const id = std.fmt.parseInt(i64, argv[0], 10) catch return error.BadInt;
    return .{ .archive = .{ .id = id } };
}

fn parseDelete(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    _ = a;
    if (argv.len < 1) return error.MissingArg;
    const id = std.fmt.parseInt(i64, argv[0], 10) catch return error.BadInt;
    return .{ .delete = .{ .id = id } };
}

fn parseOpen(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    _ = a;
    var result = OpenArgs{ .id = 0 };
    var got_id = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--pr")) {
            result.pr = true;
        } else if (std.mem.eql(u8, arg, "--issue")) {
            result.issue = true;
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .open = result };
}

fn parseConfig(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    if (argv.len == 0) return error.MissingArg;
    const sub = argv[0];

    if (std.mem.eql(u8, sub, "repo")) {
        if (argv.len < 2) return error.MissingArg;
        const action = argv[1];
        if (std.mem.eql(u8, action, "add")) {
            if (argv.len < 3) return error.MissingArg;
            return .{ .config = .{ .repo_add = .{ .path = try a.dupe(u8, argv[2]) } } };
        } else if (std.mem.eql(u8, action, "list")) {
            return .{ .config = .repo_list };
        } else if (std.mem.eql(u8, action, "remove")) {
            if (argv.len < 3) return error.MissingArg;
            return .{ .config = .{ .repo_remove = .{ .name = try a.dupe(u8, argv[2]) } } };
        }
        return error.UnknownCommand;
    } else if (std.mem.eql(u8, sub, "linear")) {
        if (argv.len < 2) return error.MissingArg;
        const action = argv[1];
        if (std.mem.eql(u8, action, "set-token")) {
            if (argv.len < 3) return error.MissingArg;
            return .{ .config = .{ .linear_set_token = .{ .token = try a.dupe(u8, argv[2]) } } };
        }
        return error.UnknownCommand;
    } else if (std.mem.eql(u8, sub, "project-root")) {
        if (argv.len < 2) return error.MissingArg;
        const action = argv[1];
        if (std.mem.eql(u8, action, "add")) {
            if (argv.len < 3) return error.MissingArg;
            return .{ .config = .{ .project_root_add = .{ .path = try a.dupe(u8, argv[2]) } } };
        } else if (std.mem.eql(u8, action, "list")) {
            return .{ .config = .project_root_list };
        } else if (std.mem.eql(u8, action, "remove")) {
            if (argv.len < 3) return error.MissingArg;
            return .{ .config = .{ .project_root_remove = .{ .path = try a.dupe(u8, argv[2]) } } };
        }
        return error.UnknownCommand;
    }

    return error.UnknownCommand;
}

fn parseSession(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    if (argv.len < 1) return error.MissingArg;
    const action = argv[0];
    if (std.mem.eql(u8, action, "set")) {
        if (argv.len < 4) return error.MissingArg;
        const id = std.fmt.parseInt(i64, argv[1], 10) catch return error.BadInt;
        const provider = try a.dupe(u8, argv[2]);
        errdefer a.free(provider);
        const sid = try a.dupe(u8, argv[3]);
        return .{ .session = .{ .set = .{ .id = id, .provider = provider, .session_id = sid } } };
    } else if (std.mem.eql(u8, action, "clear")) {
        if (argv.len < 2) return error.MissingArg;
        const id = std.fmt.parseInt(i64, argv[1], 10) catch return error.BadInt;
        return .{ .session = .{ .clear = .{ .id = id } } };
    }
    return error.UnknownCommand;
}

fn parseHandoff(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    if (argv.len < 1) return error.MissingArg;
    var result = HandoffArgs{ .id = 0 };
    var got_id = false;
    errdefer if (result.note) |n| a.free(n);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--note")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.note = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--list")) {
            result.list = true;
        } else if (std.mem.eql(u8, arg, "--latest")) {
            result.latest = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .handoff = result };
}

fn parseContext(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    _ = a;
    var result = ContextArgs{ .id = 0 };
    var got_id = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (std.mem.eql(u8, arg, "--handoffs")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.handoff_limit = std.fmt.parseInt(u32, argv[i], 10) catch return error.BadInt;
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .context = result };
}

fn parseResume(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    _ = a;
    var result = ResumeArgs{ .id = 0 };
    var got_id = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--print")) {
            result.print = true;
        } else if (std.mem.eql(u8, arg, "--fresh")) {
            result.fresh = true;
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .@"resume" = result };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "no args -> none" {
    const cmd = try parseFromArgs(std.testing.allocator, &.{});
    try std.testing.expect(cmd == .none);
}

test "refresh subcommand" {
    const args = [_][:0]u8{@constCast(@as([:0]const u8, "refresh"))};
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    try std.testing.expect(cmd == .refresh);
}

test "mcp subcommand" {
    const args = [_][:0]u8{@constCast(@as([:0]const u8, "mcp"))};
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    try std.testing.expect(cmd == .mcp);
}

test "list --json" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "list")),
        @constCast(@as([:0]const u8, "--json")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .list);
    try std.testing.expect(cmd.list.json);
}

test "list --status and --repo" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "list")),
        @constCast(@as([:0]const u8, "--status")),
        @constCast(@as([:0]const u8, "active")),
        @constCast(@as([:0]const u8, "--repo")),
        @constCast(@as([:0]const u8, "myrepo")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .list);
    try std.testing.expectEqualStrings("active", cmd.list.status.?);
    try std.testing.expectEqualStrings("myrepo", cmd.list.repo.?);
}

test "add with title and branch" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "add")),
        @constCast(@as([:0]const u8, "hello")),
        @constCast(@as([:0]const u8, "--branch")),
        @constCast(@as([:0]const u8, "feat/x")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .add);
    try std.testing.expectEqualStrings("hello", cmd.add.title);
    try std.testing.expectEqualStrings("feat/x", cmd.add.branch.?);
}

test "add with title only" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "add")),
        @constCast(@as([:0]const u8, "my task")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .add);
    try std.testing.expectEqualStrings("my task", cmd.add.title);
    try std.testing.expect(cmd.add.branch == null);
    try std.testing.expect(cmd.add.issue == null);
}

test "add missing title returns MissingArg" {
    const args = [_][:0]u8{@constCast(@as([:0]const u8, "add"))};
    const result = parseFromArgs(std.testing.allocator, &args);
    try std.testing.expectError(error.MissingArg, result);
}

test "show with id" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "show")),
        @constCast(@as([:0]const u8, "42")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    try std.testing.expect(cmd == .show);
    try std.testing.expectEqual(@as(i64, 42), cmd.show.id);
}

test "show with --json" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "show")),
        @constCast(@as([:0]const u8, "7")),
        @constCast(@as([:0]const u8, "--json")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    try std.testing.expect(cmd == .show);
    try std.testing.expectEqual(@as(i64, 7), cmd.show.id);
    try std.testing.expect(cmd.show.json);
}

test "unknown subcommand returns UnknownCommand" {
    const args = [_][:0]u8{@constCast(@as([:0]const u8, "foobar"))};
    const result = parseFromArgs(std.testing.allocator, &args);
    try std.testing.expectError(error.UnknownCommand, result);
}

test "update with id and flags" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "update")),
        @constCast(@as([:0]const u8, "5")),
        @constCast(@as([:0]const u8, "--title")),
        @constCast(@as([:0]const u8, "new title")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .update);
    try std.testing.expectEqual(@as(i64, 5), cmd.update.id);
    try std.testing.expectEqualStrings("new title", cmd.update.title.?);
}

test "archive with id" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "archive")),
        @constCast(@as([:0]const u8, "99")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    try std.testing.expect(cmd == .archive);
    try std.testing.expectEqual(@as(i64, 99), cmd.archive.id);
}

test "delete with id" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "delete")),
        @constCast(@as([:0]const u8, "3")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    try std.testing.expect(cmd == .delete);
    try std.testing.expectEqual(@as(i64, 3), cmd.delete.id);
}

test "open with --pr flag" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "open")),
        @constCast(@as([:0]const u8, "12")),
        @constCast(@as([:0]const u8, "--pr")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    try std.testing.expect(cmd == .open);
    try std.testing.expectEqual(@as(i64, 12), cmd.open.id);
    try std.testing.expect(cmd.open.pr);
    try std.testing.expect(!cmd.open.issue);
}

test "link with id and worktree" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "link")),
        @constCast(@as([:0]const u8, "8")),
        @constCast(@as([:0]const u8, "--worktree")),
        @constCast(@as([:0]const u8, "/some/path")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .link);
    try std.testing.expectEqual(@as(i64, 8), cmd.link.id);
    try std.testing.expectEqualStrings("/some/path", cmd.link.worktree.?);
}

test "unlink with id and target" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "unlink")),
        @constCast(@as([:0]const u8, "2")),
        @constCast(@as([:0]const u8, "pr")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    try std.testing.expect(cmd == .unlink);
    try std.testing.expectEqual(@as(i64, 2), cmd.unlink.id);
    try std.testing.expect(cmd.unlink.target == UnlinkTarget.pr);
}

test "config repo add" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "config")),
        @constCast(@as([:0]const u8, "repo")),
        @constCast(@as([:0]const u8, "add")),
        @constCast(@as([:0]const u8, "/my/repo")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .config);
    try std.testing.expect(cmd.config == .repo_add);
    try std.testing.expectEqualStrings("/my/repo", cmd.config.repo_add.path);
}

test "config repo list" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "config")),
        @constCast(@as([:0]const u8, "repo")),
        @constCast(@as([:0]const u8, "list")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    try std.testing.expect(cmd == .config);
    try std.testing.expect(cmd.config == .repo_list);
}

test "config linear set-token" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "config")),
        @constCast(@as([:0]const u8, "linear")),
        @constCast(@as([:0]const u8, "set-token")),
        @constCast(@as([:0]const u8, "tok123")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .config);
    try std.testing.expect(cmd.config == .linear_set_token);
    try std.testing.expectEqualStrings("tok123", cmd.config.linear_set_token.token);
}

// Leak-regression tests: std.testing.allocator panics on leak, so a clean
// exit proves errdefer freed all partial allocations on error paths.

test "parseAdd with --branch but no title leaks nothing" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "add")),
        @constCast(@as([:0]const u8, "--branch")),
        @constCast(@as([:0]const u8, "feat/x")),
    };
    const result = parseFromArgs(std.testing.allocator, &args);
    try std.testing.expectError(error.MissingArg, result);
}

test "parseAdd with --branch and --issue but no title leaks nothing" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "add")),
        @constCast(@as([:0]const u8, "--branch")),
        @constCast(@as([:0]const u8, "feat/x")),
        @constCast(@as([:0]const u8, "--issue")),
        @constCast(@as([:0]const u8, "ISS-42")),
    };
    const result = parseFromArgs(std.testing.allocator, &args);
    try std.testing.expectError(error.MissingArg, result);
}

test "parseUpdate with --title but no id leaks nothing" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "update")),
        @constCast(@as([:0]const u8, "--title")),
        @constCast(@as([:0]const u8, "new name")),
    };
    const result = parseFromArgs(std.testing.allocator, &args);
    try std.testing.expectError(error.MissingArg, result);
}

test "parseLink with --pr but no id leaks nothing" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "link")),
        @constCast(@as([:0]const u8, "--pr")),
        @constCast(@as([:0]const u8, "https://github.com/org/repo/pull/7")),
    };
    const result = parseFromArgs(std.testing.allocator, &args);
    try std.testing.expectError(error.MissingArg, result);
}

test "parseList with --status then missing value leaks nothing" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "list")),
        @constCast(@as([:0]const u8, "--repo")),
        @constCast(@as([:0]const u8, "myrepo")),
        @constCast(@as([:0]const u8, "--status")),
        // intentionally no value after --status
    };
    const result = parseFromArgs(std.testing.allocator, &args);
    try std.testing.expectError(error.MissingArg, result);
}

test "parse 'session set 5 claude abc'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "session")),
        @constCast(@as([:0]const u8, "set")),
        @constCast(@as([:0]const u8, "5")),
        @constCast(@as([:0]const u8, "claude")),
        @constCast(@as([:0]const u8, "abc-123")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqual(@as(i64, 5), cmd.session.set.id);
    try std.testing.expectEqualStrings("claude", cmd.session.set.provider);
    try std.testing.expectEqualStrings("abc-123", cmd.session.set.session_id);
}

test "parse 'handoff 7 --note hello'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "handoff")),
        @constCast(@as([:0]const u8, "7")),
        @constCast(@as([:0]const u8, "--note")),
        @constCast(@as([:0]const u8, "hello")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqual(@as(i64, 7), cmd.handoff.id);
    try std.testing.expectEqualStrings("hello", cmd.handoff.note.?);
}

test "parse 'help', '--help', '-h' all return .help" {
    inline for (.{ "help", "--help", "-h" }) |spelling| {
        const args = [_][:0]u8{@constCast(@as([:0]const u8, spelling))};
        const cmd = try parseFromArgs(std.testing.allocator, &args);
        defer freeCommand(std.testing.allocator, cmd);
        try std.testing.expectEqual(@as(@typeInfo(Command).@"union".tag_type.?, .help), cmd);
    }
}

test "parse 'resume 3 --fresh'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "resume")),
        @constCast(@as([:0]const u8, "3")),
        @constCast(@as([:0]const u8, "--fresh")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqual(@as(i64, 3), cmd.@"resume".id);
    try std.testing.expect(cmd.@"resume".fresh);
}

test "parse 'context 9 --json --handoffs 5'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "context")),
        @constCast(@as([:0]const u8, "9")),
        @constCast(@as([:0]const u8, "--json")),
        @constCast(@as([:0]const u8, "--handoffs")),
        @constCast(@as([:0]const u8, "5")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqual(@as(i64, 9), cmd.context.id);
    try std.testing.expect(cmd.context.json);
    try std.testing.expectEqual(@as(?u32, 5), cmd.context.handoff_limit);
}

test "parse 'add foo --project /tmp/p'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "add")),
        @constCast(@as([:0]const u8, "foo")),
        @constCast(@as([:0]const u8, "--project")),
        @constCast(@as([:0]const u8, "/tmp/p")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqualStrings("foo", cmd.add.title);
    try std.testing.expectEqualStrings("/tmp/p", cmd.add.project.?);
}

test "config project-root add" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "config")),
        @constCast(@as([:0]const u8, "project-root")),
        @constCast(@as([:0]const u8, "add")),
        @constCast(@as([:0]const u8, "/home/me/code")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .config);
    try std.testing.expect(cmd.config == .project_root_add);
    try std.testing.expectEqualStrings("/home/me/code", cmd.config.project_root_add.path);
}

test "config project-root list" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "config")),
        @constCast(@as([:0]const u8, "project-root")),
        @constCast(@as([:0]const u8, "list")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .config);
    try std.testing.expect(cmd.config == .project_root_list);
}

test "config project-root remove" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "config")),
        @constCast(@as([:0]const u8, "project-root")),
        @constCast(@as([:0]const u8, "remove")),
        @constCast(@as([:0]const u8, "/home/me/code")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expect(cmd == .config);
    try std.testing.expect(cmd.config == .project_root_remove);
    try std.testing.expectEqualStrings("/home/me/code", cmd.config.project_root_remove.path);
}
