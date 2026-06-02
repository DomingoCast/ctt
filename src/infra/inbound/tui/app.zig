const std = @import("std");
const vaxis = @import("vaxis");
const view = @import("view.zig");
const state_mod = @import("state.zig");
const UseCases = @import("use_cases.zig").UseCases;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
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

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    if (!vx.state.in_band_resize) try loop.installResizeHandler();

    var state = state_mod.State.init(a);
    defer state.deinit();

    // Initial load
    try doRefresh(a, uc, &state);

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |k| {
                if (k.matches('q', .{})) break;
                try handleKey(a, uc, &state, k);
            },
            .winsize => |ws| try vx.resize(a, tty.writer(), ws),
        }

        const win = vx.window();
        view.render(win, state.views, state.sel);

        // Footer with last message
        if (state.last_message) |msg| {
            _ = win.printSegment(
                .{ .text = msg },
                .{ .row_offset = win.height -| 1, .col_offset = 0 },
            );
        }

        try vx.render(tty.writer());
    }
}

fn handleKey(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, k: vaxis.Key) !void {
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
    } else if (k.matches('r', .{})) {
        try doRefresh(a, uc, state);
    } else if (k.matches('o', .{})) {
        try doOpenPr(a, state);
    } else if (k.matches('A', .{})) {
        // 'A' is shift+a; vaxis matchText handles this when text=="A"
        try doArchive(a, uc, state);
    } else if (k.matches('d', .{})) {
        try doDelete(a, uc, state);
    }
}

fn doRefresh(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State) !void {
    state.refreshing = true;
    var report = uc.refresh.execute(a, uc.repos) catch |err| {
        state.refreshing = false;
        try state.setMessage("refresh failed");
        std.log.scoped(.tui).warn("refresh: {s}", .{@errorName(err)});
        return;
    };
    defer report.deinit(a);

    // Reload the view list
    const fresh = uc.list_tasks.execute(a, .{}) catch |err| {
        state.refreshing = false;
        try state.setMessage("list failed");
        std.log.scoped(.tui).warn("list_tasks: {s}", .{@errorName(err)});
        return;
    };
    state.setViews(fresh);
    state.refreshing = false;

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
    try doRefresh(a, uc, state);
}

fn doDelete(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State) !void {
    const sel = state.selectedView() orelse return;
    uc.delete_task.execute(sel.task.id) catch {};
    try doRefresh(a, uc, state);
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
