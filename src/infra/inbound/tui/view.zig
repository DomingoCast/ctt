const std = @import("std");
const vaxis = @import("vaxis");
const d = @import("domain");
const app = @import("application");
const state_mod = @import("state.zig");
const theme_mod = @import("theme.zig");
const glyphs_mod = @import("glyphs.zig");
const card_layout = @import("card_layout.zig");

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

// Double-rounded border glyphs (╭╮╯╰ → ╔╗╝╚ style, but rounded: use ╔═╗║╝╚)
// Using proper double-line box drawing characters.
const double_border_glyphs: [6][]const u8 = .{ "╔", "═", "╗", "║", "╝", "╚" };

/// Return the first byte of `s` as a single-char slice, or "?" if empty.
/// Used as fallback icon when provider has no configured icon.
fn oneCharUpper(s: []const u8) []const u8 {
    if (s.len == 0) return "?";
    return s[0..1];
}

/// Return the display icon for a provider: template icon → first letter → generic AI glyph.
fn providerIcon(
    provider: []const u8,
    templates_lookup: *const fn ([]const u8) ?app.BuildResumeCommand.ProviderTemplate,
    glyphs: glyphs_mod.GlyphSet,
) []const u8 {
    if (templates_lookup(provider)) |tmpl| {
        if (tmpl.icon) |icon| return icon;
    }
    // No icon in config; use first letter (uppercase ASCII) as fallback, else generic AI glyph.
    if (provider.len > 0) {
        return oneCharUpper(provider);
    }
    return glyphs.ai;
}

/// Render a single card at (x_off, y_off) inside `win`.
/// Returns the height consumed (always 4: top border + title + footer + bottom border).
fn renderCard(
    win: vaxis.Window,
    x_off: i17,
    y_off: i17,
    width: u16,
    v: app.TaskView,
    status: d.Status,
    is_selected: bool,
    colors: theme_mod.ColorScheme,
    glyphs: glyphs_mod.GlyphSet,
    templates_lookup: *const fn ([]const u8) ?app.BuildResumeCommand.ProviderTemplate,
    now_unix: i64,
) u16 {
    const accent = colors.forColumn(status);
    const border_color: theme_mod.RGB = if (is_selected) accent else accent.dim();
    const border_style: vaxis.Cell.Style = .{ .fg = border_color.toVaxis() };

    const border_glyphs: vaxis.Window.BorderOptions.Glyphs = if (is_selected)
        .{ .custom = double_border_glyphs }
    else
        .single_rounded;

    const sub = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = width,
        .height = 4,
        .border = .{
            .where = .all,
            .glyphs = border_glyphs,
            .style = border_style,
        },
    });

    // === Title row (row 0 inside the card's content area) ===
    var col: u16 = 0;

    // Provider icon (if session exists)
    if (v.task.session) |sess| {
        const icon: []const u8 = providerIcon(sess.provider, templates_lookup, glyphs);
        if (icon.len > 0) {
            _ = sub.printSegment(
                .{ .text = icon, .style = .{ .fg = colors.metadata.toVaxis() } },
                .{ .row_offset = 0, .col_offset = col },
            );
            col += @intCast(sub.gwidth(icon) + 1);
        }
    }

    // Status pip
    const pip: []const u8 = if (is_selected) "◉" else "●";
    _ = sub.printSegment(
        .{ .text = pip, .style = .{ .fg = accent.toVaxis() } },
        .{ .row_offset = 0, .col_offset = col },
    );
    col += 2; // pip glyph (1 cell visual) + 1 space

    // Title (truncated)
    const inner_width: u16 = if (width > 2) width - 2 else 0;
    const title_avail: usize = if (inner_width > col) inner_width - col else 0;
    const title_slice = card_layout.truncateWithEllipsis(v.task.title, title_avail);
    _ = sub.printSegment(
        .{ .text = title_slice, .style = .{ .fg = colors.title.toVaxis() } },
        .{ .row_offset = 0, .col_offset = col },
    );
    if (title_slice.len < v.task.title.len) {
        const ell_col: u16 = col + @as(u16, @intCast(title_slice.len));
        _ = sub.printSegment(
            .{ .text = "…", .style = .{ .fg = colors.title.toVaxis() } },
            .{ .row_offset = 0, .col_offset = ell_col },
        );
    }

    // === Footer row (row 1) ===
    var footer_out: [4]card_layout.FooterField = undefined;
    var time_buf: [16]u8 = undefined;
    const fields = card_layout.cardFooterFields(v.task, status, glyphs, now_unix, &footer_out, &time_buf);
    var fcol: u16 = 0;
    const meta_style: vaxis.Cell.Style = .{ .fg = colors.metadata.toVaxis() };
    for (fields) |f| {
        if (f.glyph.len > 0) {
            _ = sub.printSegment(.{ .text = f.glyph, .style = meta_style }, .{ .row_offset = 1, .col_offset = fcol });
            fcol += @intCast(sub.gwidth(f.glyph) + 1);
        }
        _ = sub.printSegment(.{ .text = f.text, .style = meta_style }, .{ .row_offset = 1, .col_offset = fcol });
        fcol += @intCast(f.text.len + 2);
    }

    return 4;
}

pub fn render(
    win: vaxis.Window,
    views: []const app.TaskView,
    sel: Selection,
    state: *const state_mod.State,
    templates_lookup: *const fn ([]const u8) ?app.BuildResumeCommand.ProviderTemplate,
    now_unix: i64,
) void {
    win.clear();

    const col_count: u16 = COLUMNS.len;
    if (win.width < col_count * 18) {
        _ = win.printSegment(.{ .text = "terminal too narrow" }, .{});
        return;
    }
    const col_w: u16 = @intCast(win.width / col_count);

    for (COLUMNS, 0..) |col, col_idx| {
        const x_off: i17 = @intCast(col_idx * col_w);
        const accent = state.colors.forColumn(col.status);

        // Column header
        _ = win.printSegment(
            .{ .text = col.title, .style = .{ .bold = true, .fg = accent.toVaxis() } },
            .{ .row_offset = 0, .col_offset = @intCast(x_off + 2) },
        );

        // Cards
        var card_y: i17 = 2;
        var item_idx: u32 = 0;
        for (views) |v| {
            if (v.status != col.status) continue;
            const is_sel = sel.column == col_idx and sel.row == item_idx;
            const consumed = renderCard(
                win, x_off, card_y, col_w, v, col.status, is_sel,
                state.colors, state.glyphs, templates_lookup, now_unix,
            );
            card_y += @intCast(consumed + 1); // +1 row spacing between cards
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
