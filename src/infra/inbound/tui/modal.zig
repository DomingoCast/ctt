const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("state.zig");

/// Render the handoff text-area modal (G3).
/// Displays the multi-line body buffer, split on '\n'.
pub fn renderHandoff(win: vaxis.Window, m: *const state_mod.HandoffModal) void {
    const modal_w: u16 = @min(70, win.width);
    const modal_h: u16 = 16;
    const x_off: i17 = @intCast((win.width -| modal_w) / 2);
    const y_off: i17 = @intCast((win.height -| modal_h) / 2);

    const sub = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = modal_w,
        .height = modal_h,
        .border = .{ .where = .all },
    });

    _ = sub.printSegment(
        .{ .text = "Handoff (Ctrl-S save, Esc cancel)", .style = .{ .bold = true } },
        .{ .row_offset = 0, .col_offset = 2 },
    );

    // Render body lines
    var row: u16 = 2;
    const body = m.body_buf.items;
    var start: usize = 0;
    while (start <= body.len) {
        if (row >= modal_h -| 2) break;
        const nl = std.mem.indexOfScalarPos(u8, body, start, '\n');
        const end = nl orelse body.len;
        const line = body[start..end];
        const max_len: usize = if (modal_w > 5) modal_w - 5 else 0;
        const text = if (line.len > max_len) line[0..max_len] else line;
        _ = sub.printSegment(
            .{ .text = text, .style = .{ .reverse = (nl == null) } },
            .{ .row_offset = row, .col_offset = 2 },
        );
        row += 1;
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
}

pub fn renderAddTodo(win: vaxis.Window, modal: *const state_mod.AddTodoModal) void {
    const modal_w: u16 = @min(60, win.width);
    const modal_h: u16 = 9;
    const x_off: i17 = @intCast((win.width -| modal_w) / 2);
    const y_off: i17 = @intCast((win.height -| modal_h) / 2);

    const sub = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = modal_w,
        .height = modal_h,
        .border = .{ .where = .all },
    });

    _ = sub.printSegment(.{ .text = "Add Todo", .style = .{ .bold = true } }, .{ .row_offset = 0, .col_offset = 2 });

    renderField(sub, "Title ", modal.title_buf.items, modal.focus == .title, 2);
    renderField(sub, "Branch", modal.branch_buf.items, modal.focus == .branch, 4);
    renderField(sub, "Issue ", modal.issue_buf.items, modal.focus == .issue, 6);

    _ = sub.printSegment(.{ .text = "Tab next  Enter submit  Esc cancel" }, .{ .row_offset = 7, .col_offset = 2 });
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
