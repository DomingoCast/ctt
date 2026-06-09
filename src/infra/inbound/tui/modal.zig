const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("state.zig");
const repo_match = @import("repo_match.zig");

/// Render the handoff text-area modal with rounded border + glyph + dim-hint treatment.
pub fn renderHandoff(win: vaxis.Window, m: *const state_mod.HandoffModal, state: *const state_mod.State) void {
    const mw: u16 = @min(win.width -| 8, 80);
    const mh: u16 = @min(win.height -| 4, 20);
    const x_off: i17 = @intCast((win.width - mw) / 2);
    const y_off: i17 = @intCast((win.height - mh) / 2);

    const sub = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = mw,
        .height = mh,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = .{ .fg = state.colors.title.toVaxis() },
        },
    });

    var buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "{s} Handoff for #{d}", .{ state.glyphs.edit, m.task_id.raw() }) catch return;
    _ = sub.printSegment(
        .{ .text = header, .style = .{ .fg = state.colors.title.toVaxis(), .bold = true } },
        .{ .row_offset = 0, .col_offset = 2 },
    );

    // Render body lines
    var y: u16 = 2;
    const body = m.body_buf.items;
    var start: usize = 0;
    while (start <= body.len) {
        if (y >= mh -| 2) break;
        const nl = std.mem.indexOfScalarPos(u8, body, start, '\n');
        const end = nl orelse body.len;
        const line = body[start..end];
        const max_len: usize = if (mw > 5) mw - 5 else 0;
        const text = if (line.len > max_len) line[0..max_len] else line;
        _ = sub.printSegment(
            .{ .text = text, .style = .{ .fg = state.colors.title.toVaxis(), .reverse = (nl == null) } },
            .{ .row_offset = y, .col_offset = 2 },
        );
        y += 1;
        if (nl == null) break;
        start = end + 1;
    }
    // Show a cursor indicator on the last line if body is empty
    if (body.len == 0) {
        _ = sub.printSegment(
            .{ .text = " ", .style = .{ .reverse = true } },
            .{ .row_offset = 2, .col_offset = 2 },
        );
    }

    var hint_buf: [64]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, "{s} Ctrl-S save · Esc cancel", .{state.glyphs.save}) catch return;
    const hint_col: u16 = if (sub.width > hint.len + 4) sub.width - @as(u16, @intCast(hint.len)) - 2 else 2;
    _ = sub.printSegment(
        .{ .text = hint, .style = .{ .fg = state.colors.metadata.toVaxis() } },
        .{ .row_offset = sub.height -| 2, .col_offset = hint_col },
    );
}

pub fn renderAddTodo(win: vaxis.Window, modal: *const state_mod.AddTodoModal, state: *const state_mod.State) void {
    const modal_w: u16 = @min(60, win.width -| 8);

    // Compute dropdown extra rows when project is focused and dropdown is open
    const dropdown_extra: u16 = if (modal.focus == .project and modal.project_dropdown_open) blk: {
        var mb: [repo_match.MAX_RESULTS]repo_match.Match = undefined;
        const ms = repo_match.fuzzyMatch(state.cfg_repos, modal.project_buf.items, &mb);
        const hup = modal.project_buf.items.len > 0 and !exactMatchInline(ms, modal.project_buf.items);
        const rows: u16 = @intCast(ms.len + @as(usize, if (hup) 1 else 0));
        if (rows == 0) break :blk 0;
        break :blk rows + 2; // border
    } else 0;

    const base_h: u16 = 12; // header + 4 fields (2 rows each) + hint
    const modal_h: u16 = @min(base_h + dropdown_extra, win.height -| 4);

    const x_off: i17 = @intCast((win.width - modal_w) / 2);
    const y_off: i17 = @intCast((win.height - modal_h) / 2);

    const sub = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = modal_w,
        .height = modal_h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = .{ .fg = state.colors.title.toVaxis() },
        },
    });

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} New task", .{state.glyphs.edit}) catch return;
    _ = sub.printSegment(
        .{ .text = header, .style = .{ .fg = state.colors.title.toVaxis(), .bold = true } },
        .{ .row_offset = 0, .col_offset = 2 },
    );

    renderField(sub, "Title ", modal.title_buf.items, modal.focus == .title, 2);
    renderField(sub, "Branch", modal.branch_buf.items, modal.focus == .branch, 4);
    renderField(sub, "Issue ", modal.issue_buf.items, modal.focus == .issue, 6);
    renderField(sub, "Project", modal.project_buf.items, modal.focus == .project, 8);

    // Render inline dropdown when project field is focused and dropdown is open
    if (modal.focus == .project and modal.project_dropdown_open) {
        var match_buf: [repo_match.MAX_RESULTS]repo_match.Match = undefined;
        const matches = repo_match.fuzzyMatchCandidates(state.candidates, modal.project_buf.items, &match_buf);
        const has_use_path = modal.project_buf.items.len > 0 and !exactMatchInline(matches, modal.project_buf.items);
        const dropdown_rows: u16 = @intCast(matches.len + @as(usize, if (has_use_path) 1 else 0));
        if (dropdown_rows > 0) {
            const dd_w: u16 = sub.width -| 4;
            const dd_h: u16 = dropdown_rows + 2;
            const dd = sub.child(.{
                .x_off = 2,
                .y_off = 9,
                .width = dd_w,
                .height = dd_h,
                .border = .{
                    .where = .all,
                    .glyphs = .single_rounded,
                    .style = .{ .fg = state.colors.metadata.toVaxis() },
                },
            });
            var row: u16 = 0;
            for (matches, 0..) |m, i| {
                const selected = i == modal.project_selection;
                const style: vaxis.Cell.Style = if (selected)
                    .{ .reverse = true, .fg = state.colors.title.toVaxis() }
                else
                    .{ .fg = state.colors.title.toVaxis() };
                var line_buf: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "{s}  {s}", .{ m.name, m.path }) catch continue;
                _ = dd.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row, .col_offset = 2 });
                row += 1;
            }
            if (has_use_path) {
                const selected = modal.project_selection == matches.len;
                const style: vaxis.Cell.Style = if (selected)
                    .{ .reverse = true, .fg = state.colors.title.toVaxis() }
                else
                    .{ .fg = state.colors.metadata.toVaxis() };
                var line_buf: [256]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "Use path: \"{s}\"", .{modal.project_buf.items}) catch return;
                _ = dd.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row, .col_offset = 2 });
            }
        }
    }

    const hint = "Tab next  Enter submit  Esc cancel";
    const hint_col: u16 = if (sub.width > hint.len + 4) sub.width - @as(u16, @intCast(hint.len)) - 2 else 2;
    _ = sub.printSegment(
        .{ .text = hint, .style = .{ .fg = state.colors.metadata.toVaxis() } },
        .{ .row_offset = sub.height -| 2, .col_offset = hint_col },
    );
}

/// Render the help overlay listing all keybindings.
pub fn renderHelp(win: vaxis.Window, state: *const state_mod.State) void {
    const modal_w: u16 = @min(56, win.width -| 8);
    const modal_h: u16 = @min(24, win.height -| 4);
    const x_off: i17 = @intCast((win.width - modal_w) / 2);
    const y_off: i17 = @intCast((win.height - modal_h) / 2);

    const sub = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = modal_w,
        .height = modal_h,
        .border = .{
            .where = .all,
            .glyphs = .single_rounded,
            .style = .{ .fg = state.colors.title.toVaxis() },
        },
    });

    const title_style: vaxis.Cell.Style = .{ .fg = state.colors.title.toVaxis(), .bold = true };
    const key_style: vaxis.Cell.Style = .{ .fg = state.colors.title.toVaxis() };
    const desc_style: vaxis.Cell.Style = .{ .fg = state.colors.metadata.toVaxis() };
    const section_style: vaxis.Cell.Style = .{ .fg = state.colors.metadata.toVaxis(), .bold = true };

    _ = sub.printSegment(.{ .text = "Keybindings", .style = title_style }, .{ .row_offset = 0, .col_offset = 2 });

    const rows = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "Navigation", .desc = "" },
        .{ .key = "  h / l", .desc = "move between columns" },
        .{ .key = "  j / k", .desc = "move within column" },
        .{ .key = "  Enter",  .desc = "open task detail" },
        .{ .key = "", .desc = "" },
        .{ .key = "Actions", .desc = "" },
        .{ .key = "  n", .desc = "new task" },
        .{ .key = "  H", .desc = "add handoff note" },
        .{ .key = "  r", .desc = "resume task (LLM session)" },
        .{ .key = "  R", .desc = "force fresh + context" },
        .{ .key = "  A", .desc = "archive selected" },
        .{ .key = "  d", .desc = "delete selected" },
        .{ .key = "  o", .desc = "open PR in browser" },
        .{ .key = "  g", .desc = "refresh now" },
        .{ .key = "", .desc = "" },
        .{ .key = "  ?", .desc = "toggle this help" },
        .{ .key = "  Esc", .desc = "close overlay" },
        .{ .key = "  q", .desc = "quit" },
    };

    var y: u16 = 2;
    for (rows) |r| {
        if (y >= modal_h -| 2) break;
        if (r.desc.len == 0 and r.key.len > 0) {
            _ = sub.printSegment(.{ .text = r.key, .style = section_style }, .{ .row_offset = y, .col_offset = 2 });
        } else if (r.key.len > 0) {
            _ = sub.printSegment(.{ .text = r.key, .style = key_style }, .{ .row_offset = y, .col_offset = 2 });
            _ = sub.printSegment(.{ .text = r.desc, .style = desc_style }, .{ .row_offset = y, .col_offset = 14 });
        }
        y += 1;
    }
}

fn exactMatchInline(matches: []const repo_match.Match, query: []const u8) bool {
    for (matches) |m| {
        if (std.mem.eql(u8, m.name, query) or std.mem.eql(u8, m.path, query)) return true;
    }
    return false;
}

fn renderField(win: vaxis.Window, label: []const u8, value: []const u8, focused: bool, row: u16) void {
    _ = win.printSegment(.{ .text = label }, .{ .row_offset = row, .col_offset = 2 });
    _ = win.printSegment(.{ .text = ": " }, .{ .row_offset = row, .col_offset = 9 });
    const style: vaxis.Cell.Style = if (focused) .{ .reverse = true } else .{};
    if (value.len == 0) {
        _ = win.printSegment(.{ .text = " ", .style = style }, .{ .row_offset = row, .col_offset = 11 });
    } else {
        _ = win.printSegment(.{ .text = value, .style = style }, .{ .row_offset = row, .col_offset = 11 });
    }
}
