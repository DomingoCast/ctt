const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("state.zig");

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
    const modal_h: u16 = 10;
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

    const hint = "Tab next  Enter submit  Esc cancel";
    const hint_col: u16 = if (sub.width > hint.len + 4) sub.width - @as(u16, @intCast(hint.len)) - 2 else 2;
    _ = sub.printSegment(
        .{ .text = hint, .style = .{ .fg = state.colors.metadata.toVaxis() } },
        .{ .row_offset = sub.height -| 2, .col_offset = hint_col },
    );
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
