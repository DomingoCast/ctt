const std = @import("std");
const vaxis = @import("vaxis");
const d = @import("domain");
const app = @import("application");

pub const Selection = struct {
    column: u2 = 0, // 0..3
    row: u32 = 0,
};

const Column = struct { title: []const u8, status: d.Status };
const COLUMNS = [_]Column{
    .{ .title = "TODO", .status = .todo },
    .{ .title = "IN PROGRESS", .status = .in_progress },
    .{ .title = "IN REVIEW", .status = .in_review },
    .{ .title = "DONE", .status = .done },
};

pub fn render(win: vaxis.Window, views: []const app.TaskView, sel: Selection) void {
    win.clear();

    const col_count: u16 = COLUMNS.len;
    if (win.width < col_count * 12) {
        _ = win.printSegment(.{ .text = "terminal too narrow" }, .{});
        return;
    }
    const col_w: u16 = @intCast(win.width / col_count);

    for (COLUMNS, 0..) |col, col_idx| {
        const x_off: i17 = @intCast(col_idx * col_w);
        const sub = win.child(.{
            .x_off = x_off,
            .width = col_w,
            .border = .{ .where = .all },
        });

        // Header
        const header_style: vaxis.Cell.Style = .{ .bold = true };
        _ = sub.printSegment(
            .{ .text = col.title, .style = header_style },
            .{ .row_offset = 0, .col_offset = 1 },
        );

        // Cards
        var card_row: u16 = 2;
        var item_idx: u32 = 0;
        for (views) |v| {
            if (v.status != col.status) continue;
            const is_sel = sel.column == col_idx and sel.row == item_idx;
            const style: vaxis.Cell.Style = if (is_sel) .{ .reverse = true } else .{};

            _ = sub.printSegment(
                .{ .text = v.task.title, .style = style },
                .{ .row_offset = card_row, .col_offset = 1 },
            );
            card_row += 1;
            item_idx += 1;
        }
    }
}

test "Selection defaults to (0, 0)" {
    const s = Selection{};
    try std.testing.expectEqual(@as(u2, 0), s.column);
    try std.testing.expectEqual(@as(u32, 0), s.row);
}
