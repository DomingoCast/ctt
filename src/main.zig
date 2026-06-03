const std = @import("std");
const d = @import("domain");
const app = @import("application");
const cfg_mod = @import("infra_config");
const sqlite = @import("infra_sqlite");
const git = @import("infra_git");
const gh = @import("infra_gh");
const linear = @import("infra_linear");
const cli = @import("infra_cli");
const mcp = @import("infra_mcp");
const tui = @import("infra_tui");

// ---------------------------------------------------------------------------
// Entry point — new-style Zig 0.16 main with std.process.Init
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;

    // === Config paths ===
    const home = init.environ_map.get("HOME") orelse {
        std.log.err("HOME environment variable required", .{});
        return error.NoHome;
    };

    const cfg_path = try std.fmt.allocPrint(a, "{s}/.config/ctt/config.json", .{home});
    defer a.free(cfg_path);

    const secrets_path = try std.fmt.allocPrint(a, "{s}/.config/ctt/secrets.json", .{home});
    defer a.free(secrets_path);

    // === Config + secrets ===
    var cfg_parsed = cfg_mod.load(io, a, cfg_path) catch |err| {
        std.log.err("config load failed: {s} (tried {s})", .{ @errorName(err), cfg_path });
        return err;
    };
    defer cfg_parsed.deinit();
    const cfg = cfg_parsed.value;

    const maybe_token: ?[]const u8 = cfg_mod.loadSecretsToken(io, a, secrets_path) catch null;
    defer if (maybe_token) |t| a.free(t);
    const token: []const u8 = maybe_token orelse "";

    // === Open SQLite ===
    const db_path_z = try std.fmt.allocPrintSentinel(a, "{s}", .{cfg.db_path}, 0);
    defer a.free(db_path_z);
    var db = try sqlite.Db.open(db_path_z);
    defer db.close();

    // === Instantiate adapters ===
    var task_repo = sqlite.SqliteTaskRepository.init(&db);
    var handoff_repo = sqlite.SqliteHandoffRepository.init(&db);
    var git_reader = git.GitWorktreeReader.init(io);
    var gh_gateway = gh.GhPrGateway.init(io);
    var linear_gateway = linear.LinearIssueGateway.init(a, io, token);

    // === Upsert configured repos into the DB and read back ids ===
    const repos = try syncRepos(a, &db, cfg.repos);
    defer freeRepos(a, repos);

    // === Build patterns from config ===
    const patterns = try buildPatterns(a, cfg.providers.patterns);
    defer a.free(patterns);

    // === System clock ===
    const SystemClock = struct {
        const VT = d.ports.Clock.VTable{ .now = nowFn };
        fn nowFn(_: *anyopaque) d.Timestamp {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            return .{ .unix_secs = @intCast(ts.sec) };
        }
        // Use a stable non-null pointer for the clock (no state needed).
        var dummy: u8 = 0;
        fn iface() d.ports.Clock {
            return .{ .ptr = &dummy, .vtable = &VT };
        }
    };

    // === Issue gateways (currently just linear) ===
    const issue_gateways = [_]d.ports.IssueGateway{linear_gateway.interface()};

    // === Build CLI use cases ===
    var cli_uc = cli.UseCases{
        .add_todo = .{ .tasks = task_repo.interface() },
        .list_tasks = .{ .tasks = task_repo.interface() },
        .get_task = .{ .tasks = task_repo.interface() },
        .update_task = .{ .tasks = task_repo.interface() },
        .archive = .{ .tasks = task_repo.interface() },
        .delete_task = .{ .tasks = task_repo.interface() },
        .link = .{ .tasks = task_repo.interface() },
        .refresh = .{
            .tasks = task_repo.interface(),
            .worktrees = git_reader.interface(),
            .prs = gh_gateway.interface(),
            .issues = &issue_gateways,
            .clock = SystemClock.iface(),
            .patterns = patterns,
        },
        .repos = repos,
        .set_session = .{ .tasks = task_repo.interface() },
        .add_handoff = .{ .handoffs = handoff_repo.interface(), .clock = SystemClock.iface() },
        .list_handoffs = .{ .handoffs = handoff_repo.interface() },
        .get_context = .{ .tasks = task_repo.interface(), .handoffs = handoff_repo.interface() },
    };

    // === Parse command ===
    const cmd = cli.parse(a, init.minimal.args) catch |err| {
        std.log.err("arg parse: {s}", .{@errorName(err)});
        return err;
    };
    defer cli.args.freeCommand(a, cmd);

    // === stdout writer ===
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    defer stdout_w.interface.flush() catch {};

    // === Dispatch ===
    switch (cmd) {
        .none => {
            // Launch TUI
            var tui_uc = tui.UseCases{
                .add_todo = cli_uc.add_todo,
                .list_tasks = cli_uc.list_tasks,
                .get_task = cli_uc.get_task,
                .update_task = cli_uc.update_task,
                .archive = cli_uc.archive,
                .delete_task = cli_uc.delete_task,
                .link = cli_uc.link,
                .refresh = cli_uc.refresh,
                .repos = repos,
            };
            try tui.run(a, io, init.environ_map, &tui_uc);
        },
        .mcp => {
            var mcp_uc = mcp.UseCases{
                .add_todo = cli_uc.add_todo,
                .list_tasks = cli_uc.list_tasks,
                .get_task = cli_uc.get_task,
                .update_task = cli_uc.update_task,
                .archive = cli_uc.archive,
                .delete_task = cli_uc.delete_task,
                .link = cli_uc.link,
                .refresh = cli_uc.refresh,
                .repos = repos,
            };
            var stdin_buf: [4096]u8 = undefined;
            var stdin_r = std.Io.File.stdin().reader(io, &stdin_buf);
            try mcp.serve(a, &mcp_uc, &stdin_r.interface, &stdout_w.interface);
        },
        else => try cli.dispatch(a, &cli_uc, cmd, &stdout_w.interface),
    }
}

// ---------------------------------------------------------------------------
// syncRepos: upsert each configured repo and return []d.Repo with db ids
// ---------------------------------------------------------------------------

fn syncRepos(
    a: std.mem.Allocator,
    db: *sqlite.Db,
    cfg_repos: []const cfg_mod.RepoConfig,
) ![]d.Repo {
    var out: std.ArrayList(d.Repo) = .empty;
    errdefer {
        for (out.items) |r| {
            a.free(r.name);
            a.free(r.root_path);
            if (r.github) |g| a.free(g);
            a.free(r.default_branch);
        }
        out.deinit(a);
    }

    for (cfg_repos) |r| {
        // Upsert via ON CONFLICT(name)
        try db.conn.exec(
            "INSERT INTO repos (name, root_path, github, default_branch) VALUES (?, ?, ?, ?)" ++
                " ON CONFLICT(name) DO UPDATE SET" ++
                "   root_path = excluded.root_path," ++
                "   github = excluded.github," ++
                "   default_branch = excluded.default_branch",
            .{ r.name, r.path, r.github, r.default_branch },
        );

        // Read back the id
        const row = (try db.conn.row("SELECT id FROM repos WHERE name = ?", .{r.name})) orelse
            return error.RepoMissing;
        defer row.deinit();
        const id_int = row.int(0);

        try out.append(a, d.Repo{
            .id = @enumFromInt(id_int),
            .name = try a.dupe(u8, r.name),
            .root_path = try a.dupe(u8, r.path),
            .github = if (r.github) |g| try a.dupe(u8, g) else null,
            .default_branch = try a.dupe(u8, r.default_branch),
        });
    }

    return out.toOwnedSlice(a);
}

fn freeRepos(a: std.mem.Allocator, repos: []d.Repo) void {
    for (repos) |r| {
        a.free(r.name);
        a.free(r.root_path);
        if (r.github) |g| a.free(g);
        a.free(r.default_branch);
    }
    a.free(repos);
}

// ---------------------------------------------------------------------------
// buildPatterns: convert config patterns to domain patterns
// ---------------------------------------------------------------------------

fn buildPatterns(
    a: std.mem.Allocator,
    cfg_patterns: []const cfg_mod.PatternConfig,
) ![]d.ticket.ProviderPattern {
    const out = try a.alloc(d.ticket.ProviderPattern, cfg_patterns.len);
    for (cfg_patterns, 0..) |c, i| {
        out[i] = .{
            .provider = c.provider,
            .prefix_min = c.prefix_min,
            .prefix_max = c.prefix_max,
        };
    }
    return out;
}
