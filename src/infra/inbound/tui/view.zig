const std = @import("std");
const vaxis = @import("vaxis");
const d = @import("domain");
const app = @import("application");
const state_mod = @import("state.zig");

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

/// Return the first byte of `s` as a single-char slice, or "?" if empty.
/// Used as fallback icon when provider has no configured icon.
fn oneCharUpper(s: []const u8) []const u8 {
    if (s.len == 0) return "?";
    return s[0..1];
}

pub fn render(
    win: vaxis.Window,
    views: []const app.TaskView,
    sel: Selection,
    templates_lookup: *const fn ([]const u8) ?app.BuildResumeCommand.ProviderTemplate,
) void {
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

            // Provider icon (G4): show before the title when a session handle is present.
            var col_offset: u16 = 1;
            if (v.task.session) |sess| {
                const icon: []const u8 = if (templates_lookup(sess.provider)) |tmpl|
                    (tmpl.icon orelse oneCharUpper(sess.provider))
                else
                    oneCharUpper(sess.provider);
                _ = sub.printSegment(
                    .{ .text = icon, .style = style },
                    .{ .row_offset = card_row, .col_offset = col_offset },
                );
                col_offset += @intCast(icon.len + 1);
            }

            _ = sub.printSegment(
                .{ .text = v.task.title, .style = style },
                .{ .row_offset = card_row, .col_offset = col_offset },
            );
            card_row += 1;
            item_idx += 1;
        }
    }
}

/// Draw a bordered detail panel for the selected task (G1).
/// Shows task fields + up to 10 handoff bodies. ASCII only.
pub fn renderDetail(win: vaxis.Window, ds: state_mod.DetailState) void {
    const panel_w: u16 = @min(72, win.width);
    const panel_h: u16 = @min(24, win.height);
    const x_off: i17 = @intCast((win.width -| panel_w) / 2);
    const y_off: i17 = @intCast((win.height -| panel_h) / 2);

    const sub = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = panel_w,
        .height = panel_h,
        .border = .{ .where = .all },
    });

    var row: u16 = 0;

    // Title header
    _ = sub.printSegment(
        .{ .text = "Task Detail (Enter/Esc to close)", .style = .{ .bold = true } },
        .{ .row_offset = row, .col_offset = 2 },
    );
    row += 1;

    // ── Task fields ──
    printDetailField(sub, &row, "Title   ", ds.task.title, panel_w, panel_h);

    if (ds.task.branch_hint) |b| printDetailField(sub, &row, "Branch  ", b.value, panel_w, panel_h);

    if (ds.task.worktree) |wt| {
        printDetailField(sub, &row, "Worktree", wt.path, panel_w, panel_h);
    }

    if (ds.task.pr) |pr| {
        printDetailField(sub, &row, "PR      ", pr.url.value, panel_w, panel_h);
    }

    if (ds.task.issue) |iss| {
        if (iss.url) |u| printDetailField(sub, &row, "Issue   ", u, panel_w, panel_h);
    }

    if (ds.task.session) |sess| {
        // "Session  provider:session_id" — truncate to fit
        var buf: [128]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s}:{s}", .{ sess.provider, sess.session_id }) catch "...";
        printDetailField(sub, &row, "Session ", s, panel_w, panel_h);
    }

    // ── Separator ──
    if (row + 1 < panel_h -| 1) {
        _ = sub.printSegment(.{ .text = "---" }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }

    // ── Handoffs (newest first, up to 10) ──
    const limit: usize = @min(ds.handoffs.len, 10);
    for (ds.handoffs[0..limit]) |h| {
        if (row + 1 >= panel_h -| 1) break;
        // Print first line of the body only, truncated to fit
        const body_first_line = blk: {
            const nl = std.mem.indexOfScalar(u8, h.body, '\n');
            break :blk if (nl) |n| h.body[0..n] else h.body;
        };
        const max_len: usize = if (panel_w > 5) panel_w - 5 else 0;
        const text = if (body_first_line.len > max_len) body_first_line[0..max_len] else body_first_line;
        _ = sub.printSegment(.{ .text = text }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }
}

fn printDetailField(win: vaxis.Window, row: *u16, label: []const u8, value: []const u8, win_w: u16, panel_h: u16) void {
    if (row.* + 1 >= panel_h) return; // guard: don't overflow height
    _ = win.printSegment(.{ .text = label }, .{ .row_offset = row.*, .col_offset = 2 });
    _ = win.printSegment(.{ .text = ": " }, .{ .row_offset = row.*, .col_offset = 10 });
    const max_len: usize = if (win_w > 13) win_w - 13 else 0;
    const text = if (value.len > max_len) value[0..max_len] else value;
    _ = win.printSegment(.{ .text = text }, .{ .row_offset = row.*, .col_offset = 12 });
    row.* += 1;
}

test "Selection defaults to (0, 0)" {
    const s = Selection{};
    try std.testing.expectEqual(@as(u2, 0), s.column);
    try std.testing.expectEqual(@as(u32, 0), s.row);
}

test "oneCharUpper returns first byte or ?" {
    try std.testing.expectEqualStrings("c", oneCharUpper("claude"));
    try std.testing.expectEqualStrings("?", oneCharUpper(""));
}
