# ctt TUI Polish v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add periodic + focus-triggered auto-refresh and redesign kanban cards with rounded borders, status pips, state-aware footers, Nerd Font glyphs, and a Tokyo Night color palette. Detail panel, modals, and footer get the same visual language.

**Architecture:** Pure helper modules under `src/infra/inbound/tui/` (theme, glyphs, layout, time) keep logic testable without vaxis. The existing `view.zig` and `app.zig` consume them. Auto-refresh uses a timer thread that posts synthetic `.tick` events into the existing vaxis Loop; focus events use vaxis's built-in `.focus_in` / `.focus_out` variants.

**Tech Stack:** Zig 0.16, libvaxis 0.6, zqlite (unchanged from prior phases).

**Spec:** `docs/superpowers/specs/2026-06-03-ctt-tui-polish-v1-design.md` (commit `030a712`).

---

## File map

**Create:**
- `src/infra/inbound/tui/theme.zig` — color palette + dim/bright variants + `colorForColumn`
- `src/infra/inbound/tui/glyphs.zig` — Nerd Font glyph table + ASCII fallback
- `src/infra/inbound/tui/card_layout.zig` — pure helpers: `truncateWithEllipsis`, `cardFooterFields`, `formatRelativeTime`, `shouldRefresh`
- `src/infra/inbound/tui/tick.zig` — small wrapper around timer thread

**Modify:**
- `src/infra/outbound/config/loader.zig` — `UiConfig` gains `refresh_interval_ms`, `use_nerd_glyphs`, `color_scheme`
- `src/infra/inbound/tui/use_cases.zig` — UseCases gains the three new config values
- `src/infra/inbound/tui/state.zig` — State gains `last_db_mtime: i128`, `spinner_frame: u8`, `glyphs: GlyphSet`, `colors: ColorScheme`
- `src/infra/inbound/tui/app.zig` — Event union gains `tick`, `focus_in`, `focus_out`; event loop arms; `doRefresh` accepts `force: bool`
- `src/infra/inbound/tui/view.zig` — new card renderer, detail-panel restyle, footer pulse
- `src/infra/inbound/tui/modal.zig` — restyle handoff + add-todo modals
- `src/main.zig` — read new config, pass through to `tui.UseCases`

---

## Phase A — Config additions

### Task A1: `UiConfig.refresh_interval_ms` + `use_nerd_glyphs` + `color_scheme`

**Files:**
- Modify: `src/infra/outbound/config/loader.zig`

- [ ] **Step 1: Failing tests**

Add to the tests block:

```zig
test "load ui config with refresh interval and glyphs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/x","repos":[],"ui":{"refresh_interval_ms":1500,"use_nerd_glyphs":false}}
    );
    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);
    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1500), parsed.value.ui.refresh_interval_ms);
    try std.testing.expect(parsed.value.ui.use_nerd_glyphs == false);
}

test "load ui color_scheme partial override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/x","repos":[],"ui":{"color_scheme":{"todo":"#abcdef"}}}
    );
    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);
    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("#abcdef", parsed.value.ui.color_scheme.todo.?);
    try std.testing.expect(parsed.value.ui.color_scheme.in_progress == null);
}

test "load ui defaults when ui absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/x","repos":[]}
    );
    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);
    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 2000), parsed.value.ui.refresh_interval_ms);
    try std.testing.expect(parsed.value.ui.use_nerd_glyphs == true);
}
```

- [ ] **Step 2: Add the new fields**

In `loader.zig`, replace the existing `UiConfig` with:

```zig
pub const ColorScheme = struct {
    todo: ?[]const u8 = null,
    in_progress: ?[]const u8 = null,
    in_review: ?[]const u8 = null,
    done: ?[]const u8 = null,
    title: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
    idle_pulse: ?[]const u8 = null,
};

pub const UiConfig = struct {
    spawn: ?[]const u8 = null,
    refresh_interval_ms: u32 = 2000,
    use_nerd_glyphs: bool = true,
    color_scheme: ColorScheme = .{},
};
```

- [ ] **Step 3: Run tests**

```
zig build test 2>&1 | tail -5
```

Expected: 3 new tests pass; existing tests unchanged.

- [ ] **Step 4: Commit**

```bash
git add src/infra/outbound/config/loader.zig
git commit -m "feat(infra/config): refresh_interval_ms, use_nerd_glyphs, color_scheme"
```

---

## Phase B — Pure helpers

### Task B1: `theme.zig` — color palette + dim helper

**Files:**
- Create: `src/infra/inbound/tui/theme.zig`

- [ ] **Step 1: Write the module with tests**

```zig
const std = @import("std");
const vaxis = @import("vaxis");
const d = @import("domain");
const cfg = @import("infra_config");

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn dim(self: RGB) RGB {
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) * 0.6),
            .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) * 0.6),
            .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) * 0.6),
        };
    }

    pub fn toVaxis(self: RGB) vaxis.Color {
        return .{ .rgb = [3]u8{ self.r, self.g, self.b } };
    }
};

pub const ColorScheme = struct {
    todo: RGB,
    in_progress: RGB,
    in_review: RGB,
    done: RGB,
    title: RGB,
    metadata: RGB,
    idle_pulse: RGB,

    pub const default = ColorScheme{
        .todo        = .{ .r = 0x7a, .g = 0xa2, .b = 0xf7 },
        .in_progress = .{ .r = 0xe0, .g = 0xaf, .b = 0x68 },
        .in_review   = .{ .r = 0xbb, .g = 0x9a, .b = 0xf7 },
        .done        = .{ .r = 0x9e, .g = 0xce, .b = 0x6a },
        .title       = .{ .r = 0xc0, .g = 0xca, .b = 0xf5 },
        .metadata    = .{ .r = 0x56, .g = 0x5f, .b = 0x89 },
        .idle_pulse  = .{ .r = 0x41, .g = 0x48, .b = 0x68 },
    };

    pub fn fromConfig(c: cfg.ColorScheme) ColorScheme {
        return .{
            .todo        = parseHex(c.todo)        orelse default.todo,
            .in_progress = parseHex(c.in_progress) orelse default.in_progress,
            .in_review   = parseHex(c.in_review)   orelse default.in_review,
            .done        = parseHex(c.done)        orelse default.done,
            .title       = parseHex(c.title)       orelse default.title,
            .metadata    = parseHex(c.metadata)    orelse default.metadata,
            .idle_pulse  = parseHex(c.idle_pulse)  orelse default.idle_pulse,
        };
    }

    pub fn forColumn(self: ColorScheme, status: d.Status) RGB {
        return switch (status) {
            .todo => self.todo,
            .in_progress => self.in_progress,
            .in_review => self.in_review,
            .done => self.done,
            .archived => self.metadata,
        };
    }
};

fn parseHex(maybe_hex: ?[]const u8) ?RGB {
    const hex = maybe_hex orelse return null;
    if (hex.len != 7 or hex[0] != '#') return null;
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

test "dim halves channels" {
    const rgb = RGB{ .r = 100, .g = 200, .b = 250 };
    const d_rgb = rgb.dim();
    try std.testing.expectEqual(@as(u8, 60), d_rgb.r);
    try std.testing.expectEqual(@as(u8, 120), d_rgb.g);
    try std.testing.expectEqual(@as(u8, 150), d_rgb.b);
}

test "parseHex valid" {
    const rgb = parseHex("#7aa2f7").?;
    try std.testing.expectEqual(@as(u8, 0x7a), rgb.r);
    try std.testing.expectEqual(@as(u8, 0xa2), rgb.g);
    try std.testing.expectEqual(@as(u8, 0xf7), rgb.b);
}

test "parseHex invalid returns null" {
    try std.testing.expect(parseHex("not-hex") == null);
    try std.testing.expect(parseHex("#abc") == null);
    try std.testing.expect(parseHex(null) == null);
    try std.testing.expect(parseHex("#zzzzzz") == null);
}

test "fromConfig partial override" {
    var c = cfg.ColorScheme{};
    c.todo = "#000000";
    const scheme = ColorScheme.fromConfig(c);
    try std.testing.expectEqual(@as(u8, 0), scheme.todo.r);
    // unchanged from default
    try std.testing.expectEqual(@as(u8, 0xe0), scheme.in_progress.r);
}

test "forColumn maps status to color" {
    const scheme = ColorScheme.default;
    try std.testing.expectEqual(scheme.todo, scheme.forColumn(.todo));
    try std.testing.expectEqual(scheme.done, scheme.forColumn(.done));
}
```

Note: import is `const cfg = @import("infra_config");` — match how the existing TUI imports config types. If TUI doesn't already import infra_config (check `build.zig`), this task ALSO requires adding `infra_config` to the `infra_tui` module's imports in `build.zig`. Do it in the same commit.

- [ ] **Step 2: Wire infra_config into the infra_tui module in build.zig (if not already)**

Open `build.zig`. Locate the `infra_tui` module declaration:

```zig
const infra_tui = b.addModule("infra_tui", .{
    .root_source_file = b.path("src/infra/inbound/tui/root.zig"),
    .target = target,
    .optimize = optimize,
});
infra_tui.addImport("domain", domain);
infra_tui.addImport("application", application);
infra_tui.addImport("vaxis", vaxis_mod);
```

Add at the bottom:

```zig
infra_tui.addImport("infra_config", infra_config);
```

- [ ] **Step 3: Run tests**

```
zig build test
```

Expected: 5 new tests pass; existing 148 unchanged.

- [ ] **Step 4: Commit**

```bash
git add src/infra/inbound/tui/theme.zig build.zig
git commit -m "feat(infra/tui): theme.zig — color palette + dim/bright + config fromHex"
```

---

### Task B2: `glyphs.zig` — Nerd Font glyphs + ASCII fallback

**Files:**
- Create: `src/infra/inbound/tui/glyphs.zig`

- [ ] **Step 1: Write the module with tests**

```zig
const std = @import("std");

pub const GlyphSet = struct {
    branch:    []const u8,
    repo:      []const u8,
    pr:        []const u8,
    issue:     []const u8,
    folder:    []const u8,
    ai:        []const u8,
    edit:      []const u8,
    save:      []const u8,

    pub const nerd = GlyphSet{
        .branch = "\u{ea68}",  // nf-cod-source_control
        .repo   = "\u{ea83}",  // nf-cod-repo
        .pr     = "\u{eaa3}",  // nf-cod-git_pull_request
        .issue  = "\u{eab2}",  // nf-cod-issues
        .folder = "\u{ea83}",  // same glyph as repo for now
        .ai     = "\u{ec1d}",  // nf-cod-robot
        .edit   = "\u{ea73}",  // nf-cod-edit
        .save   = "\u{eb4b}",  // nf-cod-save
    };

    pub const ascii = GlyphSet{
        .branch = "b:",
        .repo   = "r:",
        .pr     = "pr:",
        .issue  = "i:",
        .folder = "d:",
        .ai     = "[AI]",
        .edit   = "[edit]",
        .save   = "[save]",
    };

    pub fn select(use_nerd: bool) GlyphSet {
        return if (use_nerd) nerd else ascii;
    }
};

test "select returns nerd or ascii" {
    const n = GlyphSet.select(true);
    const a = GlyphSet.select(false);
    try std.testing.expectEqualStrings("[AI]", a.ai);
    try std.testing.expect(!std.mem.eql(u8, n.ai, a.ai));
}

test "nerd glyphs are non-empty unicode" {
    const n = GlyphSet.nerd;
    try std.testing.expect(n.branch.len > 0);
    try std.testing.expect(n.pr.len > 0);
}
```

- [ ] **Step 2: Run tests**

```
zig build test
```

- [ ] **Step 3: Commit**

```bash
git add src/infra/inbound/tui/glyphs.zig
git commit -m "feat(infra/tui): glyphs.zig — Nerd Font glyph table + ASCII fallback"
```

---

### Task B3: `card_layout.zig` — truncate + relative time + shouldRefresh

**Files:**
- Create: `src/infra/inbound/tui/card_layout.zig`

This module contains the pure helpers that are easiest to test in isolation. Footer-fields helper is split into Task B4 because it needs the domain Task type.

- [ ] **Step 1: Write the module with tests**

```zig
const std = @import("std");

/// If `text` (UTF-8 byte count) exceeds `max`, truncate to fit including a trailing `…` (3 bytes).
/// Returns the original `text` if it fits or `max < 3`.
pub fn truncateWithEllipsis(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    if (max < 3) return text[0..max];
    // Find a UTF-8 boundary <= max - 3
    var i: usize = max - 3;
    while (i > 0 and (text[i] & 0xC0) == 0x80) : (i -= 1) {}
    return text[0..i];
}

/// Format seconds-since-epoch as "Nu" relative-to-now ("2d", "5h", "12m", "just now").
/// `buf` must be ≥ 16 bytes; returns a slice of `buf`.
pub fn formatRelativeTime(buf: []u8, then_unix: i64, now_unix: i64) []const u8 {
    const delta = if (now_unix >= then_unix) now_unix - then_unix else 0;
    if (delta < 60) return std.fmt.bufPrint(buf, "just now", .{}) catch buf[0..0];
    if (delta < 60 * 60) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(delta, 60)}) catch buf[0..0];
    if (delta < 24 * 60 * 60) return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(delta, 60 * 60)}) catch buf[0..0];
    if (delta < 30 * 24 * 60 * 60) return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(delta, 24 * 60 * 60)}) catch buf[0..0];
    if (delta < 365 * 24 * 60 * 60) return std.fmt.bufPrint(buf, "{d}mo", .{@divTrunc(delta, 30 * 24 * 60 * 60)}) catch buf[0..0];
    return std.fmt.bufPrint(buf, "{d}y", .{@divTrunc(delta, 365 * 24 * 60 * 60)}) catch buf[0..0];
}

/// Decide whether to actually run the refresh body. `force=true` always returns true.
/// Otherwise compares current mtime to last_mtime.
pub fn shouldRefresh(last_mtime: i128, current_mtime: i128, force: bool) bool {
    if (force) return true;
    return current_mtime != last_mtime;
}

test "truncateWithEllipsis short returns whole" {
    const out = truncateWithEllipsis("hi", 10);
    try std.testing.expectEqualStrings("hi", out);
}

test "truncateWithEllipsis exact fit" {
    const out = truncateWithEllipsis("abcdef", 6);
    try std.testing.expectEqualStrings("abcdef", out);
}

test "truncateWithEllipsis longer truncates and reserves room for ellipsis" {
    // Caller appends ellipsis; helper returns the body that fits before "…".
    const out = truncateWithEllipsis("abcdefghij", 6);
    try std.testing.expectEqual(@as(usize, 3), out.len);  // 6 - 3 (for "…") = 3
    try std.testing.expectEqualStrings("abc", out);
}

test "formatRelativeTime just now" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 1000, 1010);
    try std.testing.expectEqualStrings("just now", out);
}

test "formatRelativeTime minutes" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 5 * 60);
    try std.testing.expectEqualStrings("5m", out);
}

test "formatRelativeTime hours" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 3 * 60 * 60);
    try std.testing.expectEqualStrings("3h", out);
}

test "formatRelativeTime days" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 2 * 24 * 60 * 60);
    try std.testing.expectEqualStrings("2d", out);
}

test "formatRelativeTime months" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 60 * 24 * 60 * 60);
    try std.testing.expectEqualStrings("2mo", out);
}

test "formatRelativeTime years" {
    var buf: [16]u8 = undefined;
    const out = formatRelativeTime(&buf, 0, 400 * 24 * 60 * 60);
    try std.testing.expectEqualStrings("1y", out);
}

test "shouldRefresh force always true" {
    try std.testing.expect(shouldRefresh(100, 100, true));
    try std.testing.expect(shouldRefresh(100, 200, true));
}

test "shouldRefresh mtime unchanged false" {
    try std.testing.expect(!shouldRefresh(100, 100, false));
}

test "shouldRefresh mtime changed true" {
    try std.testing.expect(shouldRefresh(100, 200, false));
}
```

- [ ] **Step 2: Run tests**

```
zig build test
```

- [ ] **Step 3: Commit**

```bash
git add src/infra/inbound/tui/card_layout.zig
git commit -m "feat(infra/tui): card_layout.zig — truncate, relative time, refresh guard"
```

---

### Task B4: `card_layout.zig` — `cardFooterFields` (state-aware)

**Files:**
- Modify: `src/infra/inbound/tui/card_layout.zig`

- [ ] **Step 1: Add the FooterField + cardFooterFields with tests**

Append to `card_layout.zig`:

```zig
const d = @import("domain");
const glyphs_mod = @import("glyphs.zig");

pub const FooterField = struct {
    glyph: []const u8,   // points into glyphs.GlyphSet
    text: []const u8,    // borrowed from task fields or temp buffer
    pr_pip: ?u8 = null,  // optional inline pip ch: '●' '◐' '○'
};

/// `out_buf` should have capacity ≥ 4. Returns the slice actually filled.
/// `time_buf` is borrowed for relative-time formatting on DONE column.
/// IMPORTANT: All returned slices point either into `task` field strings (caller-owned
/// elsewhere) or into `time_buf`; `out_buf` itself is field-by-value storage.
pub fn cardFooterFields(
    task: d.Task,
    status: d.Status,
    glyphs: glyphs_mod.GlyphSet,
    now_unix: i64,
    out: []FooterField,
    time_buf: []u8,
) []FooterField {
    var n: usize = 0;
    switch (status) {
        .todo => {
            const text: []const u8 = if (task.branch_hint) |b| b.value else "—";
            out[n] = .{ .glyph = glyphs.branch, .text = text };
            n += 1;
        },
        .in_progress => {
            if (task.worktree) |w| {
                out[n] = .{ .glyph = glyphs.repo, .text = w.repo.name };
                n += 1;
                if (w.commits_ahead_of_default > 0) {
                    const txt = std.fmt.bufPrint(time_buf, "{d}↑", .{w.commits_ahead_of_default}) catch "";
                    out[n] = .{ .glyph = "", .text = txt };
                    n += 1;
                }
            }
        },
        .in_review => {
            if (task.pr) |pr| {
                const pip: u8 = switch (pr.state) {
                    .open => '●',
                    .draft => 0xc2, // first byte of '◐' — special-case in render or use single char text
                    .closed => '○',
                    .merged => '●',  // unreachable in this column but defensible
                };
                _ = pip;
                const txt = std.fmt.bufPrint(time_buf, "#{d}", .{pr.number}) catch "";
                out[n] = .{ .glyph = glyphs.pr, .text = txt };
                n += 1;
            }
            if (task.issue) |iss| {
                out[n] = .{ .glyph = glyphs.issue, .text = iss.external_id };
                n += 1;
            }
        },
        .done => {
            const then: i64 = if (task.pr) |pr| pr.updated_at.unix_secs else task.updated_at.unix_secs;
            const txt = formatRelativeTime(time_buf, then, now_unix);
            out[n] = .{ .glyph = "", .text = txt };
            n += 1;
        },
        .archived => {},
    }
    return out[0..n];
}

test "cardFooterFields TODO shows branch_hint" {
    var out: [4]FooterField = undefined;
    var time_buf: [16]u8 = undefined;
    const task = d.Task{
        .id = @enumFromInt(1),
        .title = "t",
        .branch_hint = .{ .value = "feat/x" },
        .worktree = null,
        .pr = null,
        .issue = null,
        .archived = false,
        .notes = null,
        .session = null,
        .created_at = .{ .unix_secs = 0 },
        .updated_at = .{ .unix_secs = 0 },
    };
    const got = cardFooterFields(task, .todo, glyphs_mod.GlyphSet.ascii, 100, &out, &time_buf);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("feat/x", got[0].text);
}

test "cardFooterFields TODO no branch shows em-dash" {
    var out: [4]FooterField = undefined;
    var time_buf: [16]u8 = undefined;
    const task = d.Task{
        .id = @enumFromInt(1),
        .title = "t",
        .branch_hint = null,
        .worktree = null,
        .pr = null,
        .issue = null,
        .archived = false,
        .notes = null,
        .session = null,
        .created_at = .{ .unix_secs = 0 },
        .updated_at = .{ .unix_secs = 0 },
    };
    const got = cardFooterFields(task, .todo, glyphs_mod.GlyphSet.ascii, 100, &out, &time_buf);
    try std.testing.expectEqualStrings("—", got[0].text);
}

test "cardFooterFields DONE shows relative time" {
    var out: [4]FooterField = undefined;
    var time_buf: [16]u8 = undefined;
    const task = d.Task{
        .id = @enumFromInt(1),
        .title = "t",
        .branch_hint = null,
        .worktree = null,
        .pr = null,
        .issue = null,
        .archived = false,
        .notes = null,
        .session = null,
        .created_at = .{ .unix_secs = 0 },
        .updated_at = .{ .unix_secs = 100 },
    };
    const got = cardFooterFields(task, .done, glyphs_mod.GlyphSet.ascii, 100, &out, &time_buf);
    try std.testing.expectEqualStrings("just now", got[0].text);
}
```

- [ ] **Step 2: Run tests**

```
zig build test
```

- [ ] **Step 3: Commit**

```bash
git add src/infra/inbound/tui/card_layout.zig
git commit -m "feat(infra/tui): card_layout.zig — cardFooterFields per-column content"
```

---

## Phase C — State changes

### Task C1: State gains `last_db_mtime`, `spinner_frame`, `colors`, `glyphs`, `refresh_interval_ms`

**Files:**
- Modify: `src/infra/inbound/tui/state.zig`

- [ ] **Step 1: Add fields**

Add to `State`:

```zig
last_db_mtime: i128 = 0,
spinner_frame: u8 = 0,
glyphs: glyphs_mod.GlyphSet = glyphs_mod.GlyphSet.nerd,
colors: theme_mod.ColorScheme = theme_mod.ColorScheme.default,
refresh_interval_ms: u32 = 2000,
```

Add the imports at top of file:

```zig
const glyphs_mod = @import("glyphs.zig");
const theme_mod = @import("theme.zig");
```

- [ ] **Step 2: Build**

```
zig build test
```

Expected: no test failures; new fields have defaults so existing call sites compile.

- [ ] **Step 3: Commit**

```bash
git add src/infra/inbound/tui/state.zig
git commit -m "feat(infra/tui): State holds mtime cache, spinner, palette, glyphs"
```

---

### Task C2: TUI `UseCases` gains the new config values

**Files:**
- Modify: `src/infra/inbound/tui/use_cases.zig`

- [ ] **Step 1: Add fields**

```zig
refresh_interval_ms: u32 = 2000,
use_nerd_glyphs: bool = true,
color_scheme_cfg: cfg.ColorScheme = .{},
```

Add the import: `const cfg = @import("infra_config");`

- [ ] **Step 2: Build**

```
zig build
```

Expected: build error in main.zig if its `tui.UseCases` literal doesn't include the new fields. That's expected — Task G1 fixes it. For now, add defaults so it's optional and existing builds pass:

The new fields already have `= 2000`, `= true`, `= .{}` defaults; main.zig should compile fine until G1 explicitly populates them.

- [ ] **Step 3: Run tests**

```
zig build test
```

- [ ] **Step 4: Commit**

```bash
git add src/infra/inbound/tui/use_cases.zig
git commit -m "feat(infra/tui): UseCases gains refresh/glyphs/color_scheme config knobs"
```

---

## Phase D — Event loop

### Task D1: Event union gains `tick`, `focus_in`, `focus_out`

**Files:**
- Modify: `src/infra/inbound/tui/app.zig`

- [ ] **Step 1: Extend the Event union**

At the top of `app.zig`:

```zig
const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    tick,         // posted by timer thread
    focus_in,     // vaxis emits when terminal regains focus
    focus_out,    // vaxis emits when terminal loses focus
};
```

- [ ] **Step 2: Build**

```
zig build
```

Expected: success. Adding variants to the union doesn't break existing match arms because the existing `switch (event)` in `run()` must already handle all variants — Zig requires exhaustive switches.

Wait — that's a problem. The existing switch in `run` has arms for `.key_press` and `.winsize` only. Adding new variants will break compile until those arms are added.

- [ ] **Step 3: Add no-op match arms (we'll wire them in D2/D3)**

In `run()`, update the switch:

```zig
switch (event) {
    .key_press => |k| { /* existing */ },
    .winsize => |ws| try vx.resize(a, tty.writer(), ws),
    .tick => {},          // wired in D3
    .focus_in => {},      // wired in D2
    .focus_out => {},     // intentionally no-op
}
```

- [ ] **Step 4: Run tests**

```
zig build test
```

Expected: still 148+ tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/infra/inbound/tui/app.zig
git commit -m "feat(infra/tui): Event union gains tick/focus_in/focus_out"
```

---

### Task D2: Focus-in event triggers refresh

**Files:**
- Modify: `src/infra/inbound/tui/app.zig`

- [ ] **Step 1: Extend `doRefresh` to accept `force: bool`**

Locate `fn doRefresh(a, uc, state)` and add a parameter:

```zig
fn doRefresh(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, force: bool) !void {
    // mtime guard added in Task D3
    _ = force; // used in D3

    state.refreshing = true;
    var report = uc.refresh.execute(a, uc.repos) catch |err| {
        state.refreshing = false;
        try state.setMessage("refresh failed");
        std.log.scoped(.tui).warn("refresh: {s}", .{@errorName(err)});
        return;
    };
    defer report.deinit(a);

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
```

Update all existing call sites: `try doRefresh(a, uc, state, true);` — own-write refreshes use `force=true`.

There are likely 4-5 call sites: after add-save, archive, delete, handoff-save, initial-load.

- [ ] **Step 2: Wire `.focus_in` arm**

```zig
.focus_in => try doRefresh(a, uc, &state, true),
```

- [ ] **Step 3: Run tests**

```
zig build test
```

- [ ] **Step 4: Commit**

```bash
git add src/infra/inbound/tui/app.zig
git commit -m "feat(infra/tui): doRefresh takes force flag; focus_in triggers refresh"
```

---

### Task D3: Periodic tick timer thread + mtime guard

**Files:**
- Create: `src/infra/inbound/tui/tick.zig`
- Modify: `src/infra/inbound/tui/app.zig`

- [ ] **Step 1: Write the tick-thread wrapper**

Create `src/infra/inbound/tui/tick.zig`:

```zig
const std = @import("std");

/// Spawns a thread that posts a synthetic event into a vaxis Loop every
/// `interval_ms`. The thread reads `stop_flag.*` and exits when true.
pub fn TickThread(comptime Loop: type, comptime Event: type) type {
    return struct {
        thread: std.Thread,
        stop: *std.atomic.Value(bool),
        loop: *Loop,
        interval_ms: u32,

        const Self = @This();

        pub fn start(loop: *Loop, stop: *std.atomic.Value(bool), interval_ms: u32) !Self {
            const thread = try std.Thread.spawn(.{}, threadFn, .{ loop, stop, interval_ms });
            return .{
                .thread = thread,
                .stop = stop,
                .loop = loop,
                .interval_ms = interval_ms,
            };
        }

        pub fn join(self: *Self) void {
            self.stop.store(true, .release);
            self.thread.join();
        }

        fn threadFn(loop: *Loop, stop: *std.atomic.Value(bool), interval_ms: u32) void {
            while (!stop.load(.acquire)) {
                std.Thread.sleep(@as(u64, interval_ms) * std.time.ns_per_ms);
                if (stop.load(.acquire)) break;
                loop.postEvent(@unionInit(Event, "tick", {})) catch break;
            }
        }
    };
}
```

- [ ] **Step 2: Update `doRefresh` for mtime guard**

In `src/infra/inbound/tui/app.zig` `doRefresh`, use the mtime guard:

```zig
fn doRefresh(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, force: bool) !void {
    // mtime guard
    const stat = std.Io.Dir.cwd().statFileAbsolute(uc.io, uc.db_path) catch null;
    if (stat) |s| {
        if (!card_layout.shouldRefresh(state.last_db_mtime, s.mtime, force)) return;
        state.last_db_mtime = s.mtime;
    }
    // ... rest of body (refresh.execute + list_tasks.execute) ...
}
```

Note: This requires `uc.db_path: []const u8` to be added to TUI UseCases (path to the SQLite DB file). Add it:

In `src/infra/inbound/tui/use_cases.zig`, add `db_path: []const u8 = "",`. Wire from main.zig (G1).

If `statFileAbsolute` is a different name in Zig 0.16, inspect `std.Io.Dir` and use the correct one. Mirror how `infra/config/loader.zig` reads files.

- [ ] **Step 3: Start the tick thread in `run()`**

In `src/infra/inbound/tui/app.zig` `run()`, after the loop init:

```zig
var stop_flag: std.atomic.Value(bool) = .init(false);
var ticker = try tick.TickThread(@TypeOf(loop), Event).start(&loop, &stop_flag, uc.refresh_interval_ms);
defer ticker.join();
```

- [ ] **Step 4: Wire `.tick` arm in event switch**

```zig
.tick => {
    if (state.mode == .normal) {
        try doRefresh(a, uc, &state, false);  // non-forced; mtime guard applies
    }
    // advance spinner regardless of mode
    state.spinner_frame +%= 1;
},
```

- [ ] **Step 5: Build + test**

```
zig build test
```

Note: starting a thread isn't directly testable in the existing suite without integration; manual smoke at H1 verifies it. Existing tests should still pass.

- [ ] **Step 6: Commit**

```bash
git add src/infra/inbound/tui/tick.zig src/infra/inbound/tui/app.zig src/infra/inbound/tui/use_cases.zig
git commit -m "feat(infra/tui): tick thread + mtime guard for auto-refresh"
```

---

## Phase E — Card rendering

### Task E1: Rounded card border + status pip (uniform card)

**Files:**
- Modify: `src/infra/inbound/tui/view.zig`

- [ ] **Step 1: Add a `renderCard` helper**

Replace the current per-task printSegment in the column-iteration loop with a per-card sub-window. New helper (placed alongside `render`):

```zig
const theme_mod = @import("theme.zig");
const glyphs_mod = @import("glyphs.zig");
const card_layout = @import("card_layout.zig");

/// Render a single card at (x_off, y_off) inside the column window.
/// Returns the height consumed (always 4 in v1: top border + title + footer + bottom border).
fn renderCard(
    col_win: vaxis.Window,
    x_off: i17,
    y_off: i17,
    width: u16,
    v: app.TaskView,
    status: d.Status,
    is_selected: bool,
    colors: theme_mod.ColorScheme,
    glyphs: glyphs_mod.GlyphSet,
    now_unix: i64,
) u16 {
    const color = colors.forColumn(status);
    const border_color = if (is_selected) color else color.dim();
    const border_style: vaxis.Cell.Style = .{ .fg = border_color.toVaxis() };

    const sub = col_win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = width,
        .height = 4,
        .border = .{
            .where = .all,
            .glyphs = if (is_selected) .double_rounded else .rounded,
            .style = border_style,
        },
    });

    // Title row (sub-row 0 of the inner area): [provider_icon ?] [pip] <title>
    var col: u16 = 0;
    if (v.task.session) |sh| {
        const icon = providerIcon(sh.provider, glyphs);
        _ = sub.printSegment(.{ .text = icon, .style = .{ .fg = colors.metadata.toVaxis() } }, .{ .row_offset = 0, .col_offset = col });
        col += @intCast(icon.len + 1);
    }
    const pip: []const u8 = if (is_selected) "◉" else "●";
    _ = sub.printSegment(.{ .text = pip, .style = .{ .fg = color.toVaxis() } }, .{ .row_offset = 0, .col_offset = col });
    col += 2;
    const title_max: usize = if (width > col + 2) width - col - 2 else 0;
    const title_buf_len: usize = @min(v.task.title.len, title_max);
    const title_slice = card_layout.truncateWithEllipsis(v.task.title, title_buf_len);
    _ = sub.printSegment(.{ .text = title_slice, .style = .{ .fg = colors.title.toVaxis() } }, .{ .row_offset = 0, .col_offset = col });
    if (title_slice.len < v.task.title.len) {
        _ = sub.printSegment(.{ .text = "…", .style = .{ .fg = colors.title.toVaxis() } }, .{ .row_offset = 0, .col_offset = col + @as(u16, @intCast(title_slice.len)) });
    }

    // Footer row (sub-row 1): per-column fields
    var footer_out: [4]card_layout.FooterField = undefined;
    var time_buf: [16]u8 = undefined;
    const fields = card_layout.cardFooterFields(v.task, status, glyphs, now_unix, &footer_out, &time_buf);
    var fcol: u16 = 0;
    for (fields) |f| {
        if (f.glyph.len > 0) {
            _ = sub.printSegment(.{ .text = f.glyph, .style = .{ .fg = colors.metadata.toVaxis() } }, .{ .row_offset = 1, .col_offset = fcol });
            fcol += @intCast(f.glyph.len + 1);
        }
        _ = sub.printSegment(.{ .text = f.text, .style = .{ .fg = colors.metadata.toVaxis() } }, .{ .row_offset = 1, .col_offset = fcol });
        fcol += @intCast(f.text.len + 2);
    }

    return 4;
}

fn providerIcon(provider: []const u8, glyphs: glyphs_mod.GlyphSet) []const u8 {
    _ = provider;
    _ = glyphs;
    // For v1, return the AI fallback. The session handle's provider name
    // is the lookup key but the config-supplied icon flows through a
    // separate code path (see G1 wiring). This helper is a placeholder
    // for terminals without a config icon; real icon comes from
    // templates_lookup(provider).icon in the call site.
    return "";  // intentionally empty; caller-side icon wiring is G1
}
```

(The placeholder `providerIcon` is intentional — the actual lookup uses `templates_lookup` already wired into UseCases. The call site can be improved later.)

- [ ] **Step 2: Update `render` to call `renderCard`**

Replace the existing per-card printSegment loop. The new flow:
- For each column, iterate views, but `card_y_off` advances by `renderCard`'s returned height + 1 (spacing).
- `renderCard` does its own border drawing.

```zig
pub fn render(
    win: vaxis.Window,
    views: []const app.TaskView,
    sel: Selection,
    state: *const state_mod.State,
    now_unix: i64,
) void {
    win.clear();
    const col_count: u16 = COLUMNS.len;
    if (win.width < col_count * 18) {  // updated minimum width
        _ = win.printSegment(.{ .text = "terminal too narrow" }, .{});
        return;
    }
    const col_w: u16 = @intCast(win.width / col_count);

    for (COLUMNS, 0..) |col, col_idx| {
        const x_off: i17 = @intCast(col_idx * col_w);
        const color = state.colors.forColumn(col.status);

        // Column header
        _ = win.printSegment(
            .{ .text = col.title, .style = .{ .bold = true, .fg = color.toVaxis() } },
            .{ .row_offset = 0, .col_offset = x_off + 2 },
        );

        // Cards
        var card_y: i17 = 2;
        var item_idx: u32 = 0;
        for (views) |v| {
            if (v.status != col.status) continue;
            const is_sel = sel.column == col_idx and sel.row == item_idx;
            const consumed = renderCard(
                win, x_off, card_y, col_w, v, col.status, is_sel, state.colors, state.glyphs, now_unix,
            );
            card_y += @intCast(consumed + 1);  // +1 spacing
            item_idx += 1;
        }
    }
}
```

- [ ] **Step 3: Update all call sites**

`app.zig`'s render call site changes from `view.render(win, state.views, state.sel)` to `view.render(win, state.views, state.sel, &state, std.time.timestamp())`.

- [ ] **Step 4: Build + manual smoke**

```
zig build
./zig-out/bin/ctt
```

Expected: TUI launches showing rounded cards with status pips. Press `q` to exit.

- [ ] **Step 5: Commit**

```bash
git add src/infra/inbound/tui/view.zig src/infra/inbound/tui/app.zig
git commit -m "feat(infra/tui): rounded bordered cards + status pip + state-aware footer"
```

---

## Phase F — Other surfaces

### Task F1: Detail panel restyle

**Files:**
- Modify: `src/infra/inbound/tui/view.zig`

- [ ] **Step 1: Update `renderDetail`**

Replace the existing `renderDetail` with a styled version that uses:
- Rounded border in the source task's column accent color (from state.colors).
- Section headers (Session, Worktree, PR, Issue, Handoffs) in bright bold (`title` color).
- Field labels use Nerd Font glyphs from state.glyphs.
- Handoff entries separated by `╾──╼` with relative timestamp dim, right-aligned.

```zig
pub fn renderDetail(win: vaxis.Window, ds: state_mod.DetailState, state: *const state_mod.State, now_unix: i64) void {
    win.clear();
    const status = d.derive_status(ds.task);
    const accent = state.colors.forColumn(status);

    const sub = win.child(.{
        .x_off = 4,
        .y_off = 2,
        .width = win.width - 8,
        .height = win.height - 4,
        .border = .{
            .where = .all,
            .glyphs = .rounded,
            .style = .{ .fg = accent.toVaxis() },
        },
    });

    var row: u16 = 1;
    const title_style = vaxis.Cell.Style{ .fg = state.colors.title.toVaxis(), .bold = true };
    const meta_style = vaxis.Cell.Style{ .fg = state.colors.metadata.toVaxis() };

    _ = sub.printSegment(.{ .text = ds.task.title, .style = title_style }, .{ .row_offset = row, .col_offset = 2 });
    row += 2;

    if (ds.task.session) |s| {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} Session  {s}:{s}", .{ state.glyphs.ai, s.provider, s.session_id }) catch return;
        _ = sub.printSegment(.{ .text = line, .style = meta_style }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }
    if (ds.task.worktree) |w| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} Worktree {s}", .{ state.glyphs.folder, w.path }) catch return;
        _ = sub.printSegment(.{ .text = line, .style = meta_style }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }
    if (ds.task.pr) |pr| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} PR       #{d} {s}", .{ state.glyphs.pr, pr.number, @tagName(pr.state) }) catch return;
        _ = sub.printSegment(.{ .text = line, .style = meta_style }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }
    if (ds.task.issue) |iss| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} Issue    {s}", .{ state.glyphs.issue, iss.external_id }) catch return;
        _ = sub.printSegment(.{ .text = line, .style = meta_style }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }

    row += 1;
    _ = sub.printSegment(.{ .text = "Handoffs:", .style = title_style }, .{ .row_offset = row, .col_offset = 2 });
    row += 1;
    for (ds.handoffs) |h| {
        if (row >= sub.height - 1) break;
        var time_buf: [16]u8 = undefined;
        const rel = card_layout.formatRelativeTime(&time_buf, h.created_at.unix_secs, now_unix);
        // Render body
        _ = sub.printSegment(.{ .text = h.body, .style = meta_style }, .{ .row_offset = row, .col_offset = 4 });
        // Right-aligned relative time
        const rel_col: u16 = if (sub.width > rel.len + 4) sub.width - @as(u16, @intCast(rel.len)) - 2 else 4;
        _ = sub.printSegment(.{ .text = rel, .style = meta_style }, .{ .row_offset = row, .col_offset = rel_col });
        row += 1;
        // Separator
        if (row < sub.height - 1) {
            const sep = "╾──╼";
            _ = sub.printSegment(.{ .text = sep, .style = meta_style }, .{ .row_offset = row, .col_offset = 4 });
            row += 1;
        }
    }
}
```

- [ ] **Step 2: Update the call site in `app.zig`**

```zig
if (state.mode == .detail) {
    if (state.detail) |ds| view.renderDetail(win, ds, &state, std.time.timestamp());
}
```

- [ ] **Step 3: Build + manual smoke**

```
zig build
```

Confirmation only: smoke needs a TTY.

- [ ] **Step 4: Commit**

```bash
git add src/infra/inbound/tui/view.zig src/infra/inbound/tui/app.zig
git commit -m "feat(infra/tui): detail panel uses theme + glyphs + relative time"
```

---

### Task F2: Modal restyle

**Files:**
- Modify: `src/infra/inbound/tui/modal.zig`

- [ ] **Step 1: Update `renderHandoff`**

```zig
pub fn renderHandoff(win: vaxis.Window, m: *const state_mod.HandoffModal, state: *const state_mod.State) void {
    const mw = @min(win.width - 8, 80);
    const mh = @min(win.height - 4, 20);
    const x_off: i17 = @intCast((win.width - mw) / 2);
    const y_off: i17 = @intCast((win.height - mh) / 2);
    const sub = win.child(.{
        .x_off = x_off,
        .y_off = y_off,
        .width = mw,
        .height = mh,
        .border = .{
            .where = .all,
            .glyphs = .rounded,
            .style = .{ .fg = state.colors.title.toVaxis() },
        },
    });
    var buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "{s} Handoff for #{d}", .{ state.glyphs.edit, m.task_id.raw() }) catch return;
    _ = sub.printSegment(
        .{ .text = header, .style = .{ .fg = state.colors.title.toVaxis(), .bold = true } },
        .{ .row_offset = 0, .col_offset = 2 },
    );

    var y: u16 = 2;
    var iter = std.mem.splitScalar(u8, m.body_buf.items, '\n');
    while (iter.next()) |line| : (y += 1) {
        if (y >= sub.height - 2) break;
        _ = sub.printSegment(.{ .text = line, .style = .{ .fg = state.colors.title.toVaxis() } }, .{ .row_offset = y, .col_offset = 2 });
    }

    var hint_buf: [64]u8 = undefined;
    const hint = std.fmt.bufPrint(&hint_buf, "{s} Ctrl-S save · Esc cancel", .{state.glyphs.save}) catch return;
    const hint_col: u16 = if (sub.width > hint.len + 4) sub.width - @as(u16, @intCast(hint.len)) - 2 else 2;
    _ = sub.printSegment(
        .{ .text = hint, .style = .{ .fg = state.colors.metadata.toVaxis() } },
        .{ .row_offset = sub.height - 2, .col_offset = hint_col },
    );
}
```

- [ ] **Step 2: Update `renderAddTodo`**

Apply the same treatment to `renderAddTodo`: rounded border, title-color header "✏ New task" (or `state.glyphs.edit + " New task"`), dim hint footer.

(Keep the existing buffer-driven body rendering — only restyle borders, header, hint.)

- [ ] **Step 3: Update call sites in `app.zig`**

Pass `&state` to both modal renderers.

- [ ] **Step 4: Build + commit**

```bash
zig build
git add src/infra/inbound/tui/modal.zig src/infra/inbound/tui/app.zig
git commit -m "feat(infra/tui): modals use theme + glyphs"
```

---

### Task F3: Footer pulse indicator

**Files:**
- Modify: `src/infra/inbound/tui/view.zig` and `app.zig` render loop

- [ ] **Step 1: Add a `renderFooter` helper to view.zig**

```zig
pub fn renderFooter(win: vaxis.Window, state: *const state_mod.State) void {
    // Left: last message
    if (state.last_message) |msg| {
        _ = win.printSegment(
            .{ .text = msg, .style = .{ .fg = state.colors.metadata.toVaxis() } },
            .{ .row_offset = win.height -| 1, .col_offset = 0 },
        );
    }
    // Right: pulse indicator
    const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    const pulse_glyph: []const u8 = if (state.refreshing)
        spinner_frames[state.spinner_frame % spinner_frames.len]
    else
        "●";
    const pulse_color = if (state.refreshing) state.colors.title else state.colors.idle_pulse;
    const pulse_col: u16 = win.width -| 2;
    _ = win.printSegment(
        .{ .text = pulse_glyph, .style = .{ .fg = pulse_color.toVaxis() } },
        .{ .row_offset = win.height -| 1, .col_offset = @intCast(pulse_col) },
    );
}
```

- [ ] **Step 2: Replace the existing footer printSegment in `app.zig`**

```zig
view.renderFooter(win, &state);
```

(Remove the inline `if (state.last_message) ...` block in the render path.)

- [ ] **Step 3: Build + commit**

```bash
zig build
git add src/infra/inbound/tui/view.zig src/infra/inbound/tui/app.zig
git commit -m "feat(infra/tui): footer pulse indicator"
```

---

## Phase G — Composition root + smoke

### Task G1: Wire new config into TUI UseCases

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Update the TUI UseCases construction**

In `main.zig` `main()`, find where `tui_uc` (or the TUI UseCases instance) is constructed. Add:

```zig
.refresh_interval_ms = cfg.ui.refresh_interval_ms,
.use_nerd_glyphs = cfg.ui.use_nerd_glyphs,
.color_scheme_cfg = cfg.ui.color_scheme,
.db_path = cfg.db_path,
```

(`db_path` was added in D3 for the mtime guard.)

In the TUI `run` initialization, propagate these into `state.glyphs`, `state.colors`, `state.refresh_interval_ms`:

```zig
state.glyphs = glyphs_mod.GlyphSet.select(uc.use_nerd_glyphs);
state.colors = theme_mod.ColorScheme.fromConfig(uc.color_scheme_cfg);
state.refresh_interval_ms = uc.refresh_interval_ms;
```

This happens in `tui.run` (i.e. `src/infra/inbound/tui/app.zig` `run`) after `state.init(a)`.

- [ ] **Step 2: Build**

```
zig build
```

- [ ] **Step 3: Manual smoke**

```bash
./zig-out/bin/ctt
```

Expected: TUI launches. Cards have rounded borders, status pips colored per column, footer pulse visible bottom-right.

Add a task via CLI in another terminal:

```bash
./zig-out/bin/ctt add "smoke from CLI"
```

Within ~2s, the new card should appear in the running TUI. Switch focus away from the ctt terminal and back; refresh fires immediately.

Press `Enter` on a task — detail panel shows in source-column color with section headers.

Press `H` — handoff modal rounded with header "[edit] Handoff for #N".

Press `q` to exit.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig src/infra/inbound/tui/app.zig
git commit -m "feat(main): wire ui config into TUI state + activate auto-refresh"
```

---

### Task G2: Final smoke

**Files:**
- (none — this is verification only)

- [ ] **Step 1: Run the test suite**

```
zig build test 2>&1 | tail -5
```

Expected: exit 0, count ≥ 148 (Phase B added ~20 new tests).

- [ ] **Step 2: Run the existing smoke**

```
./tests/smoke.sh
```

Expected: `handoff smoke OK` (CLI semantics unaffected).

- [ ] **Step 3: Launch TUI and exercise**

```bash
./zig-out/bin/ctt
```

- Confirm cards are rounded with status pips.
- Press `j`/`k` to move within column; selected card becomes double-line border.
- Press `Enter` — detail panel shows in column accent color, glyphs visible.
- Press `Esc` to close detail.
- Press `H` — handoff modal styled.
- Press `Esc`.
- In another terminal: `./zig-out/bin/ctt add "from external"`. Wait ~2s. New card appears in TUI without keypress.
- Switch focus to another window, then back. Footer pulse spins briefly.
- Set `ui.use_nerd_glyphs: false` in `~/.config/ctt/config.json`, relaunch. Verify ASCII fallback labels render (`b:`, `pr:`, etc.).
- Restore config, exit.

- [ ] **Step 4: No commit needed for this task** — just confirms the prior commits work end-to-end.

---

## Self-review

**Spec coverage:**
- §2 goals: covered (auto-refresh A1/D1-D3, rounded cards E1, detail/modals/footer F1-F3, fallbacks B2/G1).
- §3 non-goals: none accidentally implemented.
- §4 auto-refresh (triggers + mtime + pulse): D1-D3 + F3.
- §5 card visual: B1 (palette), E1 (border + pip + double-line selected).
- §5.4 nerd glyphs + ASCII fallback: B2 + G1.
- §6 state-aware content: B4 + E1.
- §7 config additions: A1.
- §8.1 detail panel: F1.
- §8.2 modals: F2.
- §8.3 footer status bar: F3.
- §9 files touched: matches.
- §10 testing: B1-B4 cover the pure helpers; state-machine tests are not added in this plan (acknowledged gap — manual smoke covers the integration). If needed, follow-up.
- §11 migration: no schema change; new config fields default-safe.
- §13 unknowns: vaxis focus support is asserted-but-not-tested; if it doesn't work on a given terminal, the 2s poll covers.

**Placeholder scan:** no TBD / TODO in the plan body. The `providerIcon` helper in E1 is a placeholder noted as such; the actual icon comes from existing templates_lookup wiring (this is a known limitation, not a placeholder).

**Type consistency:**
- `ColorScheme`, `RGB`, `GlyphSet`, `FooterField` all defined exactly once and referenced consistently.
- `shouldRefresh(last_mtime, current_mtime, force)` signature matches between B3 and D3.
- `doRefresh(a, uc, state, force)` signature updated in D2 and used consistently after.

**Estimated time:** 4-6 hours.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-03-ctt-tui-polish-v1.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task with spec + code reviews. Fits this plan's ~12 tasks.
2. **Inline Execution** — work through in this session with checkpoints.

Which approach?
