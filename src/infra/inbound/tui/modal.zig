const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("state.zig");

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
