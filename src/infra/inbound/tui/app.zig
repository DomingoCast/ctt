const std = @import("std");
const vaxis = @import("vaxis");
const view = @import("view.zig");
const state_mod = @import("state.zig");
const modal_mod = @import("modal.zig");
const UseCases = @import("use_cases.zig").UseCases;
const d = @import("domain");
const app = @import("application");
const card_layout = @import("card_layout.zig");
const tick = @import("tick.zig");
const glyphs_mod = @import("glyphs.zig");
const theme_mod = @import("theme.zig");
const repo_match = @import("repo_match.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    tick, // posted by timer thread (Task D3)
    focus_in, // vaxis emits when terminal regains focus
    focus_out, // vaxis emits when terminal loses focus
};

/// Run the TUI event loop.
///
/// Callers must supply `io` (a `std.Io` backend) and `env_map` (the process
/// environment map) because libvaxis 0.6 requires both at construction time.
/// A typical `main` obtains these from `std.Io.Threaded` and
/// `std.process.Environ.createMap`. `uc` provides access to all use-cases
/// plus the configured repos list.
pub fn run(
    a: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    uc: *UseCases,
) !void {
    // Provide a stack buffer for the TTY writer.
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, a, env_map, .{});
    defer vx.deinit(a, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    var stop_flag = std.atomic.Value(bool).init(false);
    var ticker = try tick.TickThread(@TypeOf(loop), Event).start(&loop, &stop_flag, uc.refresh_interval_ms);
    defer ticker.join();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    if (!vx.state.in_band_resize) try loop.installResizeHandler();

    var state = state_mod.State.init(a);
    defer state.deinit();

    state.glyphs = glyphs_mod.GlyphSet.select(uc.use_nerd_glyphs);
    state.colors = theme_mod.ColorScheme.fromConfig(uc.color_scheme_cfg);
    state.refresh_interval_ms = uc.refresh_interval_ms;
    state.cfg_repos = uc.cfg_repos;
    state.candidates = uc.candidates;
    state.fzf_available = uc.fzf_available;

    // Initial load
    try doRefresh(a, uc, &state, true);

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |k| {
                // 'q' only exits in normal mode
                if (state.mode == .normal and k.matches('q', .{})) break;
                try handleKey(a, uc, &state, k);
            },
            .winsize => |ws| try vx.resize(a, tty.writer(), ws),
            .tick => {
                state.spinner_frame +%= 1; // advance regardless of mode (footer animation)
                if (state.mode == .normal) {
                    try doRefresh(a, uc, &state, false); // non-forced; mtime guard applies
                }
            },
            .focus_in => try doRefresh(a, uc, &state, true),
            .focus_out => {}, // intentionally no-op
        }

        const win = vx.window();
        var now_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &now_ts);
        view.render(win, state.views, state.sel, &state, uc.templates_lookup, now_ts.sec);

        // Footer: last message + pulse indicator
        view.renderFooter(win, &state);

        // Overlay modals / panels
        switch (state.mode) {
            .add_todo_modal => modal_mod.renderAddTodo(win, &state.add_todo_modal, &state),
            .detail => if (state.detail) |ds| view.renderDetail(win, ds, &state, now_ts.sec),
            .handoff_modal => if (state.handoff_modal) |*hm| modal_mod.renderHandoff(win, hm, &state),
            .help_modal => modal_mod.renderHelp(win, &state),
            .normal => {},
        }

        try vx.render(tty.writer());
    }
}

fn handleKey(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, k: vaxis.Key) !void {
    switch (state.mode) {
        .normal => try handleNormalKey(a, uc, state, k),
        .add_todo_modal => try handleModalKey(a, uc, state, k),
        .detail => try handleDetailKey(a, state, k),
        .handoff_modal => try handleHandoffModalKey(a, uc, state, k),
        .help_modal => try handleHelpModalKey(state, k),
    }
}

fn handleHelpModalKey(state: *state_mod.State, k: vaxis.Key) !void {
    if (k.matches(vaxis.Key.escape, .{}) or k.matches('?', .{}) or k.matches('q', .{})) {
        state.mode = .normal;
    }
}

fn handleNormalKey(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, k: vaxis.Key) !void {
    if (k.matches('h', .{}) or k.matches(vaxis.Key.left, .{})) {
        if (state.sel.column > 0) state.sel.column -= 1;
        state.sel.row = 0;
    } else if (k.matches('l', .{}) or k.matches(vaxis.Key.right, .{})) {
        if (state.sel.column < 3) state.sel.column += 1;
        state.sel.row = 0;
    } else if (k.matches('j', .{}) or k.matches(vaxis.Key.down, .{})) {
        const max = state.columnCount(state.sel.column);
        if (max > 0 and state.sel.row + 1 < max) state.sel.row += 1;
    } else if (k.matches('k', .{}) or k.matches(vaxis.Key.up, .{})) {
        if (state.sel.row > 0) state.sel.row -= 1;
    } else if (k.matches(vaxis.Key.enter, .{})) {
        // G1: open detail panel
        const sel = state.selectedView() orelse return;
        const ctx = (try uc.get_context.execute(a, sel.task.id, 20)) orelse return;
        state.detail = .{ .task = ctx.task, .handoffs = ctx.handoffs };
        state.mode = .detail;
    } else if (k.matches('r', .{})) {
        // G2: resume (soft — reuse existing session)
        try doResume(a, uc, state, false);
    } else if (k.matches('R', .{})) {
        // G2: force-fresh resume (ignore existing session)
        try doResume(a, uc, state, true);
    } else if (k.matches('g', .{})) {
        // Refresh (formerly 'r' — rebound to 'g' to free 'r' for resume)
        try doRefresh(a, uc, state, true);
    } else if (k.matches('H', .{})) {
        // G3: open handoff modal
        const sel = state.selectedView() orelse return;
        state.handoff_modal = .{ .task_id = sel.task.id };
        state.mode = .handoff_modal;
    } else if (k.matches('o', .{})) {
        try doOpenPr(a, state);
    } else if (k.matches('A', .{})) {
        // 'A' is shift+a; vaxis matchText handles this when text=="A"
        try doArchive(a, uc, state);
    } else if (k.matches('d', .{})) {
        try doDelete(a, uc, state);
    } else if (k.matches('n', .{})) {
        state.mode = .add_todo_modal;
    } else if (k.matches('?', .{})) {
        state.mode = .help_modal;
    }
}

fn handleModalKey(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, k: vaxis.Key) !void {
    const modal = &state.add_todo_modal;

    if (k.matches(vaxis.Key.escape, .{})) {
        modal.reset(a);
        state.mode = .normal;
        return;
    }

    if (modal.focus == .project) {
        return handleProjectFieldKey(a, uc, state, k);
    }

    if (k.matches(vaxis.Key.enter, .{})) {
        try submitAddTodo(a, uc, state);
        return;
    }
    if (k.matches(vaxis.Key.tab, .{})) {
        modal.cycleFocus();
        return;
    }
    if (k.matches(vaxis.Key.backspace, .{})) {
        const buf = modal.focused();
        if (buf.items.len > 0) _ = buf.pop();
        return;
    }
    // Typed character: vaxis exposes printable text via Key.text
    if (k.text) |t| {
        const buf = modal.focused();
        try buf.appendSlice(a, t);
    }
}

fn handleProjectFieldKey(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, k: vaxis.Key) !void {
    const modal = &state.add_todo_modal;

    var match_buf: [repo_match.MAX_RESULTS]repo_match.Match = undefined;
    const matches = repo_match.fuzzyMatchCandidates(uc.candidates, modal.project_buf.items, &match_buf);
    const has_use_path = modal.project_buf.items.len > 0 and !exactMatch(matches, modal.project_buf.items);
    const visible: u8 = @intCast(matches.len + @as(usize, if (has_use_path) 1 else 0));

    if (k.matches(vaxis.Key.up, .{})) {
        if (modal.project_selection > 0) modal.project_selection -= 1;
        modal.project_dropdown_open = true;
        return;
    }
    if (k.matches(vaxis.Key.down, .{})) {
        if (modal.project_selection + 1 < visible) modal.project_selection += 1;
        modal.project_dropdown_open = true;
        return;
    }
    if (k.matches(vaxis.Key.tab, .{})) {
        if (modal.project_dropdown_open and visible > 0) {
            try acceptProjectSelection(a, modal, matches, has_use_path);
        }
        modal.project_dropdown_open = false;
        modal.cycleFocus();
        return;
    }
    if (k.matches(vaxis.Key.enter, .{})) {
        if (modal.project_dropdown_open and visible > 0) {
            try acceptProjectSelection(a, modal, matches, has_use_path);
            modal.project_dropdown_open = false;
            return;
        }
        try submitAddTodo(a, uc, state);
        return;
    }
    if (k.matches(vaxis.Key.backspace, .{})) {
        if (modal.project_buf.items.len > 0) _ = modal.project_buf.pop();
        modal.project_selection = 0;
        modal.project_dropdown_open = true;
        return;
    }
    if (k.text) |t| {
        try modal.project_buf.appendSlice(a, t);
        modal.project_selection = 0;
        modal.project_dropdown_open = true;
        return;
    }
}

fn exactMatch(matches: []const repo_match.Match, query: []const u8) bool {
    for (matches) |m| {
        if (std.mem.eql(u8, m.name, query) or std.mem.eql(u8, m.path, query)) return true;
    }
    return false;
}

fn acceptProjectSelection(
    a: std.mem.Allocator,
    modal: *state_mod.AddTodoModal,
    matches: []const repo_match.Match,
    has_use_path: bool,
) !void {
    const sel = modal.project_selection;
    if (sel < matches.len) {
        // Configured repo: copy its path into project_buf
        modal.project_buf.clearRetainingCapacity();
        try modal.project_buf.appendSlice(a, matches[sel].path);
    } else if (has_use_path) {
        // "Use path: X" — keep the raw input as-is (std.Io.Dir 0.16 has no realpath)
    }
    modal.project_selection = 0;
}

/// G1: Handle keys while the task detail panel is open.
fn handleDetailKey(a: std.mem.Allocator, state: *state_mod.State, k: vaxis.Key) !void {
    _ = a;
    if (k.matches(vaxis.Key.escape, .{}) or k.matches(vaxis.Key.enter, .{})) {
        if (state.detail) |*ds| ds.deinit(state.allocator);
        state.detail = null;
        state.mode = .normal;
    }
}

/// G3: Handle keys while the handoff text-area modal is open.
fn handleHandoffModalKey(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, k: vaxis.Key) !void {
    var m = &state.handoff_modal.?;
    if (k.matches(vaxis.Key.escape, .{})) {
        m.deinit(a);
        state.handoff_modal = null;
        state.mode = .normal;
        return;
    }
    if (k.matches('s', .{ .ctrl = true })) {
        if (m.body_buf.items.len > 0) {
            _ = try uc.add_handoff.execute(a, m.task_id, m.body_buf.items);
            try doRefresh(a, uc, state, true);
        }
        m.deinit(a);
        state.handoff_modal = null;
        state.mode = .normal;
        return;
    }
    if (k.matches(vaxis.Key.backspace, .{})) {
        if (m.body_buf.items.len > 0) _ = m.body_buf.pop();
        return;
    }
    if (k.matches(vaxis.Key.enter, .{})) {
        try m.body_buf.append(a, '\n');
        return;
    }
    if (k.text) |t| try m.body_buf.appendSlice(a, t);
}

fn submitAddTodo(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State) !void {
    const modal = &state.add_todo_modal;
    if (modal.title_buf.items.len == 0) {
        try state.setMessage("title required");
        return;
    }

    // Validate project path if provided
    const project_raw = modal.project_buf.items;
    if (project_raw.len > 0) {
        _ = std.Io.Dir.statFile(std.Io.Dir.cwd(), uc.io, project_raw, .{}) catch {
            const msg = try std.fmt.allocPrint(a, "path not found: {s}", .{project_raw});
            defer a.free(msg);
            try state.setMessage(msg);
            return;
        };
    }
    const project_path: ?[]const u8 = if (project_raw.len > 0) project_raw else null;

    const branch_hint: ?d.BranchName = if (modal.branch_buf.items.len > 0)
        d.BranchName.init(modal.branch_buf.items)
    else
        null;

    const t = uc.add_todo.execute(a, .{
        .title = modal.title_buf.items,
        .branch_hint = branch_hint,
        .project_path = project_path,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(a, "add failed: {s}", .{@errorName(err)});
        defer a.free(msg);
        try state.setMessage(msg);
        return;
    };

    const msg = try std.fmt.allocPrint(a, "added task #{d}", .{t.id.raw()});
    defer a.free(msg);
    try state.setMessage(msg);

    modal.reset(a);
    state.mode = .normal;
    try doRefresh(a, uc, state, true);
}

fn doRefresh(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, force: bool) !void {
    // mtime guard — skip work if DB unchanged and not forced
    // pending_mtime is held here and committed only after full success so that a
    // failure mid-refresh does not advance the cache and suppress future retries.
    var pending_mtime: ?i128 = null;
    if (uc.db_path.len > 0) {
        const stat_ok_mtime = blk: {
            const file = std.Io.Dir.openFileAbsolute(uc.io, uc.db_path, .{}) catch break :blk null;
            defer file.close(uc.io);
            const s = file.stat(uc.io) catch break :blk null;
            break :blk s.mtime.nanoseconds;
        };
        if (stat_ok_mtime) |current_mtime| {
            const cm: i128 = @intCast(current_mtime);
            if (!card_layout.shouldRefresh(state.last_db_mtime, cm, force)) return;
            pending_mtime = cm; // hold; don't commit until full success
        }
    }

    state.refreshing = true;
    var report = uc.refresh.execute(a, uc.repos) catch |err| {
        state.refreshing = false;
        try state.setMessage("refresh failed");
        std.log.scoped(.tui).warn("refresh: {s}", .{@errorName(err)});
        // pending_mtime intentionally not committed on failure
        return;
    };
    defer report.deinit(a);

    // Reload the view list
    const fresh = uc.list_tasks.execute(a, .{}) catch |err| {
        state.refreshing = false;
        try state.setMessage("list failed");
        std.log.scoped(.tui).warn("list_tasks: {s}", .{@errorName(err)});
        // pending_mtime intentionally not committed on failure
        return;
    };
    state.setViews(fresh);
    state.refreshing = false;

    // Commit mtime only after both operations succeeded so a future tick can
    // retry on the same mtime if the refresh was interrupted above.
    if (pending_mtime) |m| state.last_db_mtime = m;

    const msg = try std.fmt.allocPrint(a, "refresh: +{d} tasks · +{d} prs · +{d} issues", .{
        report.tasks_created,
        report.prs_updated,
        report.issues_updated,
    });
    defer a.free(msg);
    try state.setMessage(msg);
}

fn doArchive(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State) !void {
    const sel = state.selectedView() orelse return;
    _ = uc.archive.execute(a, sel.task.id, !sel.task.archived) catch {};
    try doRefresh(a, uc, state, true);
}

fn doDelete(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State) !void {
    const sel = state.selectedView() orelse return;
    uc.delete_task.execute(sel.task.id) catch {};
    try doRefresh(a, uc, state, true);
}

fn doOpenPr(a: std.mem.Allocator, state: *state_mod.State) !void {
    const sel = state.selectedView() orelse return;
    const url = if (sel.task.pr) |pr| pr.url.value else null;
    if (url) |u| {
        const msg = try std.fmt.allocPrint(a, "URL: {s} (press 'q' to copy from log)", .{u});
        defer a.free(msg);
        try state.setMessage(msg);
        // Future: spawn `open` / `xdg-open` here. For v1, just show the URL in the footer.
    } else {
        try state.setMessage("no PR url for this task");
    }
}

/// G2: Resume the selected task via the configured provider template.
/// `force_fresh = true` (bound to 'R') ignores any existing session handle and
/// uses the "fresh" template instead; `false` (bound to 'r') prefers the resume
/// template when a session handle exists.
///
/// Spawn behaviour: the TUI keeps running — we detach the child process with
/// `spawn` but do NOT `wait`. The terminal multiplexer (tmux/wezterm etc.) is
/// expected to open a new window/pane; the kanban stays visible.
/// If no spawn_template is configured, the rendered command is printed in the
/// footer instead of spawned (copy-paste fallback).
fn doResume(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, force_fresh: bool) !void {
    const sel = state.selectedView() orelse return;

    const ctx = (try uc.get_context.execute(a, sel.task.id, 1)) orelse {
        try state.setMessage("no context for task");
        return;
    };
    defer {
        for (ctx.handoffs) |h| a.free(h.body);
        a.free(ctx.handoffs);
        app.freeTask(a, ctx.task);
    }

    // Write the latest handoff body (if any) to a temp file for {{context_file}}.
    const runtime_dir: []const u8 = if (std.c.getenv("XDG_RUNTIME_DIR")) |p| std.mem.span(p) else "/tmp";
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    const path = try std.fmt.allocPrint(
        a,
        "{s}/ctt-handoff-{d}-{d}-{d}.md",
        .{ runtime_dir, sel.task.id.raw(), ts.sec, ts.nsec },
    );
    defer a.free(path);

    const body: []const u8 = if (ctx.handoffs.len > 0) ctx.handoffs[0].body else "";
    writeContextFile(uc.io, path, body) catch |err| {
        const msg = try std.fmt.allocPrint(a, "resume: failed to write context file: {s}", .{@errorName(err)});
        defer a.free(msg);
        try state.setMessage(msg);
        return;
    };
    // NOTE: we deliberately do NOT use defer-delete for the temp file here. The
    // spawn below is detached (we don't wait for the child), so deleting on
    // doResume return would race the child's $(cat ...) substitution. The file
    // is in $XDG_RUNTIME_DIR or /tmp, both of which the OS cleans up between
    // sessions (or on a schedule). The accumulated litter per session is bounded
    // by how many `r` keypresses the user makes — small in practice.
    // Non-spawn return paths below delete the file inline.

    const no_spawn = uc.spawn_template == null;
    const cmd = app.BuildResumeCommand.build(a, .{
        .templates = uc.templates_lookup,
        .default_provider = uc.default_provider,
        .session = ctx.task.session,
        .context_file = path,
        // When no spawn template configured, render without wrapper for display.
        .spawn_wrapper = if (no_spawn) null else uc.spawn_template,
        .force_fresh = force_fresh,
    }) catch |err| {
        // Build error: file was written but no spawn will happen — clean up.
        std.Io.Dir.deleteFileAbsolute(uc.io, path) catch {};
        const msg = try std.fmt.allocPrint(a, "resume: {s}", .{@errorName(err)});
        defer a.free(msg);
        try state.setMessage(msg);
        return;
    };
    defer a.free(cmd.command);

    if (no_spawn) {
        const launcher_kind = uc.terminal_launcher.kind;
        if (launcher_kind == .none) {
            // No multiplexer configured and no known terminal detected:
            // print the command in the footer (legacy fallback). File unused.
            std.Io.Dir.deleteFileAbsolute(uc.io, path) catch {};
            const msg = try std.fmt.allocPrint(a, "resume cmd: {s}", .{cmd.command});
            defer a.free(msg);
            try state.setMessage(msg);
            return;
        }

        // Open a new terminal window via the auto-detected launcher.
        // cwd = task.project_path or $HOME (or "/" as a last resort).
        const home_z = std.c.getenv("HOME");
        const fallback_cwd: []const u8 = if (home_z) |p| std.mem.span(p) else "/";
        const spawn_cwd_path: []const u8 = if (ctx.task.project_path) |p| p else fallback_cwd;

        const terminal_launcher = @import("terminal_launcher.zig");
        const argv = terminal_launcher.buildArgv(
            a,
            uc.terminal_launcher,
            spawn_cwd_path,
            cmd.command,
        ) catch |err| {
            std.Io.Dir.deleteFileAbsolute(uc.io, path) catch {};
            const m = try std.fmt.allocPrint(a, "resume failed: {s}", .{@errorName(err)});
            defer a.free(m);
            try state.setMessage(m);
            return;
        };
        defer terminal_launcher.freeArgv(a, argv);

        _ = std.process.spawn(uc.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            std.Io.Dir.deleteFileAbsolute(uc.io, path) catch {};
            const m = try std.fmt.allocPrint(a, "resume failed: {s}", .{@errorName(err)});
            defer a.free(m);
            try state.setMessage(m);
            return;
        };
        // Do NOT delete the temp file — the launched terminal reads it asynchronously.

        const m = try std.fmt.allocPrint(a, "spawned in {s}", .{@tagName(launcher_kind)});
        defer a.free(m);
        try state.setMessage(m);
        return;
    }

    // Detached spawn: /bin/sh -c <cmd>. The TUI keeps running; do NOT wait.
    // Do NOT delete the temp file here — the child reads it asynchronously.
    // If the task has a project_path, set it as the cwd of the spawned process.
    const spawn_cwd: std.process.Child.Cwd = if (ctx.task.project_path) |p|
        .{ .path = p }
    else
        .inherit;
    const child = std.process.spawn(uc.io, .{
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd.command },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .cwd = spawn_cwd,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(a, "resume failed: {s}", .{@errorName(err)});
        defer a.free(msg);
        try state.setMessage(msg);
        return;
    };
    _ = child; // child.wait is intentionally omitted — detached

    const mode_str = if (force_fresh) "force-fresh" else "resume";
    const msg = try std.fmt.allocPrint(a, "spawned ({s})", .{mode_str});
    defer a.free(msg);
    try state.setMessage(msg);
}

fn writeContextFile(io: std.Io, path: []const u8, body: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{
        .truncate = true,
        .permissions = @enumFromInt(0o600),
    });
    defer file.close(io);
    try file.writeStreamingAll(io, body);
}
