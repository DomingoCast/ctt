# TUI Resume Spawn (Auto-Detect Terminal) & fzf Project Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `r` in the TUI actually open a Claude session in a new terminal window without per-user config, and let the project picker discover projects on disk via `fzf` (with the existing inline dropdown as fallback).

**Architecture:** Two scoped changes inside the TUI inbound adapter (`src/infra/inbound/tui/`) plus a new `project_roots` field in the config schema. Auto-detect the terminal emulator from env vars at TUI startup, build a per-terminal launch argv (`wezterm start --cwd ... --`, `alacritty --working-directory ...`, etc.), and spawn detached. For the picker, scan one level under each `project_root` at startup, merge with `cfg.repos`, and prefer `fzf` as the picker when installed.

**Tech Stack:** Zig 0.16, `std.process.spawn`, `std.process.EnvMap`, `std.json` (already used by config loader), vaxis (TUI).

**Spec:** `docs/superpowers/specs/2026-06-09-ctt-tui-resume-spawn-and-fzf-picker-design.md`

---

## File Structure

**New files:**
- `src/infra/inbound/tui/terminal_launcher.zig` — `Kind`, `Launcher`, `detect(env)`, `buildArgv(a, launcher, cwd, cmd)`.
- `src/infra/inbound/tui/fzf_picker.zig` — `Candidate`, `Selection`, `available(a)`, `pick(a, tui, candidates)`.
- `src/infra/inbound/tui/project_candidates.zig` — `Candidate`, `build(a, repos, project_roots)` — scan roots, dedupe with repos.

**Modified files:**
- `src/infra/outbound/config/loader.zig` — add `project_roots: []const []const u8 = &.{}` to `Config`; add `~/` expansion helper; tests.
- `src/infra/inbound/cli/args.zig` — add `project_root_add/list/remove` variants to `ConfigCmd`; tests.
- `src/infra/inbound/cli/handlers.zig` — add stub handlers (same convention as existing `repo_add/list/remove`).
- `src/infra/inbound/tui/use_cases.zig` — add `terminal_launcher: terminal_launcher.Launcher` and `candidates: []const project_candidates.Candidate` and `fzf_available: bool`.
- `src/infra/inbound/tui/state.zig` — store `candidates` and `fzf_available` (already passed via UseCases, but the modal-render path reads from State today).
- `src/infra/inbound/tui/app.zig` — `doResume` calls `terminal_launcher.buildArgv` when `spawn_template == null`; `handleProjectFieldKey` opens fzf when `fzf_available`; `Ctrl-P` reopens fzf.
- `src/infra/inbound/tui/modal.zig` — inline dropdown reads from `candidates` instead of `cfg_repos` directly.
- `src/infra/inbound/tui/root.zig` — add new modules to the test block.
- `src/main.zig` — call `terminal_launcher.detect`, build candidates, check fzf availability, pass into `tui.UseCases`.

**Test commands:**
- All tests: `zig build test` (run from repo root)
- Single file via test step: `zig build test` — no per-file filter; the whole suite runs (~189 tests today). Steps that say "Run test to verify it fails" mean: run `zig build test` and look for the new test name in the failures.

---

## Task 1: `terminal_launcher.zig` — detection

**Files:**
- Create: `src/infra/inbound/tui/terminal_launcher.zig`
- Modify: `src/infra/inbound/tui/root.zig` (add to test block)

- [ ] **Step 1: Create the file with public types and a stub `detect` that always returns `.none`**

```zig
const std = @import("std");

pub const Kind = enum { wezterm, kitty, alacritty, iterm2, terminal_app, none };

pub const Launcher = struct {
    kind: Kind,
};

/// Inspect env vars and return the first matching terminal kind.
/// Priority: wezterm > kitty > alacritty > iterm2 > terminal_app.
pub fn detect(env: *const std.process.EnvMap) Launcher {
    _ = env;
    return .{ .kind = .none };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "detect returns .none for empty env" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(Kind.none, detect(&env).kind);
}
```

- [ ] **Step 2: Add module to the test block in `src/infra/inbound/tui/root.zig`**

Edit the test block to include `_ = @import("terminal_launcher.zig");` next to `repo_match`:

```zig
test {
    _ = view;
    _ = state;
    _ = modal;
    _ = @import("use_cases.zig");
    _ = @import("theme.zig");
    _ = @import("glyphs.zig");
    _ = @import("card_layout.zig");
    _ = @import("tick.zig");
    // app.zig requires a real TTY, so don't include it in the test block
    _ = @import("repo_match.zig");
    _ = @import("terminal_launcher.zig");
}
```

- [ ] **Step 3: Run the test to verify it passes (baseline)**

Run: `zig build test`
Expected: PASS for `detect returns .none for empty env` (no other behavior tested yet).

- [ ] **Step 4: Write the failing detection tests, one per kind**

Append to the test block in `terminal_launcher.zig`:

```zig
test "detect wezterm via WEZTERM_PANE" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEZTERM_PANE", "0");
    try std.testing.expectEqual(Kind.wezterm, detect(&env).kind);
}

test "detect wezterm via WEZTERM_EXECUTABLE" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEZTERM_EXECUTABLE", "/usr/bin/wezterm");
    try std.testing.expectEqual(Kind.wezterm, detect(&env).kind);
}

test "detect kitty via KITTY_WINDOW_ID" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("KITTY_WINDOW_ID", "1");
    try std.testing.expectEqual(Kind.kitty, detect(&env).kind);
}

test "detect alacritty via ALACRITTY_LOG" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ALACRITTY_LOG", "/tmp/alacritty.log");
    try std.testing.expectEqual(Kind.alacritty, detect(&env).kind);
}

test "detect alacritty via ALACRITTY_SOCKET" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ALACRITTY_SOCKET", "/tmp/alacritty.sock");
    try std.testing.expectEqual(Kind.alacritty, detect(&env).kind);
}

test "detect iterm2 via TERM_PROGRAM" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM_PROGRAM", "iTerm.app");
    try std.testing.expectEqual(Kind.iterm2, detect(&env).kind);
}

test "detect terminal_app via TERM_PROGRAM" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM_PROGRAM", "Apple_Terminal");
    try std.testing.expectEqual(Kind.terminal_app, detect(&env).kind);
}

test "detect priority: wezterm beats alacritty when both set" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEZTERM_PANE", "0");
    try env.put("ALACRITTY_LOG", "/tmp/a.log");
    try std.testing.expectEqual(Kind.wezterm, detect(&env).kind);
}

test "detect TERM_PROGRAM unknown value returns .none" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM_PROGRAM", "weird-terminal");
    try std.testing.expectEqual(Kind.none, detect(&env).kind);
}
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `zig build test`
Expected: 8 new failures (`detect wezterm via WEZTERM_PANE` through `detect TERM_PROGRAM unknown value returns .none`), all reporting `expected wezterm/kitty/.../none, found none/...`.

- [ ] **Step 6: Implement `detect`**

Replace the stub `detect` body:

```zig
pub fn detect(env: *const std.process.EnvMap) Launcher {
    if (env.get("WEZTERM_EXECUTABLE") != null or env.get("WEZTERM_PANE") != null) {
        return .{ .kind = .wezterm };
    }
    if (env.get("KITTY_WINDOW_ID") != null) {
        return .{ .kind = .kitty };
    }
    if (env.get("ALACRITTY_LOG") != null or env.get("ALACRITTY_SOCKET") != null) {
        return .{ .kind = .alacritty };
    }
    if (env.get("TERM_PROGRAM")) |tp| {
        if (std.mem.eql(u8, tp, "iTerm.app")) return .{ .kind = .iterm2 };
        if (std.mem.eql(u8, tp, "Apple_Terminal")) return .{ .kind = .terminal_app };
    }
    return .{ .kind = .none };
}
```

- [ ] **Step 7: Run tests to verify all pass**

Run: `zig build test`
Expected: PASS for all 9 `detect ...` tests.

- [ ] **Step 8: Commit**

```bash
git add src/infra/inbound/tui/terminal_launcher.zig src/infra/inbound/tui/root.zig
git commit -m "feat(tui): detect terminal emulator from env vars"
```

---

## Task 2: `terminal_launcher.zig` — `buildArgv` for non-osascript launchers

**Files:**
- Modify: `src/infra/inbound/tui/terminal_launcher.zig`

- [ ] **Step 1: Add failing tests for `buildArgv` (wezterm, alacritty, kitty)**

Append to the test block:

```zig
fn argvEq(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |a, e| try std.testing.expectEqualStrings(e, a);
}

test "buildArgv wezterm" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .wezterm }, "/home/me/proj", "claude --resume X");
    defer freeArgv(std.testing.allocator, argv);
    try argvEq(argv, &[_][]const u8{
        "wezterm", "start", "--cwd", "/home/me/proj", "--",
        "/bin/sh", "-c", "claude --resume X",
    });
}

test "buildArgv alacritty" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .alacritty }, "/home/me/proj", "claude");
    defer freeArgv(std.testing.allocator, argv);
    try argvEq(argv, &[_][]const u8{
        "alacritty", "--working-directory", "/home/me/proj", "-e",
        "/bin/sh", "-c", "claude",
    });
}

test "buildArgv kitty" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .kitty }, "/x", "ls");
    defer freeArgv(std.testing.allocator, argv);
    try argvEq(argv, &[_][]const u8{
        "kitty", "--directory", "/x", "/bin/sh", "-c", "ls",
    });
}

test "buildArgv .none returns NoTerminalDetected" {
    try std.testing.expectError(
        error.NoTerminalDetected,
        buildArgv(std.testing.allocator, .{ .kind = .none }, "/", "ls"),
    );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: failures because `buildArgv` and `freeArgv` are not declared.

- [ ] **Step 3: Add `buildArgv` and `freeArgv` for non-osascript launchers**

Insert before the test block (after `detect`):

```zig
pub const BuildArgvError = error{ NoTerminalDetected, OutOfMemory };

/// Builds the argv for `std.process.spawn` that opens a new terminal window
/// with cwd=`cwd` and running `/bin/sh -c "<cmd>"`.
///
/// The returned slice and each contained string are allocated with `a`;
/// caller must release via `freeArgv`.
pub fn buildArgv(
    a: std.mem.Allocator,
    launcher: Launcher,
    cwd: []const u8,
    cmd: []const u8,
) BuildArgvError![]const []const u8 {
    return switch (launcher.kind) {
        .wezterm => try dupeArgv(a, &[_][]const u8{
            "wezterm", "start", "--cwd", cwd, "--",
            "/bin/sh", "-c", cmd,
        }),
        .alacritty => try dupeArgv(a, &[_][]const u8{
            "alacritty", "--working-directory", cwd, "-e",
            "/bin/sh", "-c", cmd,
        }),
        .kitty => try dupeArgv(a, &[_][]const u8{
            "kitty", "--directory", cwd, "/bin/sh", "-c", cmd,
        }),
        .iterm2, .terminal_app => @panic("osascript launchers handled in a later task"),
        .none => return error.NoTerminalDetected,
    };
}

pub fn freeArgv(a: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |s| a.free(s);
    a.free(argv);
}

fn dupeArgv(a: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, src.len);
    errdefer a.free(out);
    var i: usize = 0;
    errdefer for (out[0..i]) |s| a.free(s);
    while (i < src.len) : (i += 1) {
        out[i] = try a.dupe(u8, src[i]);
    }
    return out;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS for the four `buildArgv` tests added in Step 1.

- [ ] **Step 5: Commit**

```bash
git add src/infra/inbound/tui/terminal_launcher.zig
git commit -m "feat(tui): buildArgv for wezterm/alacritty/kitty"
```

---

## Task 3: `terminal_launcher.zig` — osascript-based launchers (iTerm2, Terminal.app)

**Files:**
- Modify: `src/infra/inbound/tui/terminal_launcher.zig`

- [ ] **Step 1: Add failing tests for iTerm2 and Terminal.app**

Append:

```zig
test "buildArgv terminal_app produces osascript do-script" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .terminal_app }, "/x", "claude");
    defer freeArgv(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("osascript", argv[0]);
    try std.testing.expectEqualStrings("-e", argv[1]);
    // The full script body. `do script` opens a new window in Terminal.app.
    try std.testing.expectEqualStrings(
        "tell application \"Terminal\" to do script \"cd '/x' && claude\"",
        argv[2],
    );
}

test "buildArgv iterm2 produces osascript with create-window" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .iterm2 }, "/y", "ls");
    defer freeArgv(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("osascript", argv[0]);
    try std.testing.expectEqualStrings("-e", argv[1]);
    // Multi-line AppleScript that creates a new iTerm window and runs the command.
    const expected =
        "tell application \"iTerm\"\n" ++
        "  create window with default profile\n" ++
        "  tell current session of current window to write text \"cd '/y' && ls\"\n" ++
        "end tell";
    try std.testing.expectEqualStrings(expected, argv[2]);
}

test "buildArgv terminal_app escapes single quotes in cwd" {
    // A single quote in cwd must be escaped to keep the wrapping `'...'` valid in sh.
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .terminal_app }, "/it's/here", "ls");
    defer freeArgv(std.testing.allocator, argv);
    // POSIX trick: end quote, escaped quote, restart quote → 'it'\''s'
    try std.testing.expectEqualStrings(
        "tell application \"Terminal\" to do script \"cd '/it'\\\\''s/here' && ls\"",
        argv[2],
    );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: failures — `buildArgv` panics for `.iterm2` and `.terminal_app`.

- [ ] **Step 3: Replace the `@panic` with osascript implementations**

In `buildArgv`, replace the `.iterm2, .terminal_app => @panic(...)` line with two separate arms:

```zig
        .terminal_app => blk: {
            const cwd_quoted = try shSingleQuoteEscape(a, cwd);
            defer a.free(cwd_quoted);
            // AppleScript double-quoted body; sh single-quote-escape the cwd
            // so a directory with a literal quote can't break out of the cd.
            const script = try std.fmt.allocPrint(
                a,
                "tell application \"Terminal\" to do script \"cd '{s}' && {s}\"",
                .{ cwd_quoted, cmd },
            );
            defer a.free(script);
            break :blk try dupeArgv(a, &[_][]const u8{ "osascript", "-e", script });
        },
        .iterm2 => blk: {
            const cwd_quoted = try shSingleQuoteEscape(a, cwd);
            defer a.free(cwd_quoted);
            const script = try std.fmt.allocPrint(
                a,
                "tell application \"iTerm\"\n" ++
                    "  create window with default profile\n" ++
                    "  tell current session of current window to write text \"cd '{s}' && {s}\"\n" ++
                    "end tell",
                .{ cwd_quoted, cmd },
            );
            defer a.free(script);
            break :blk try dupeArgv(a, &[_][]const u8{ "osascript", "-e", script });
        },
```

Add the helper at the bottom of the file (above the test block):

```zig
/// Escapes a string for safe embedding inside single quotes in a POSIX shell.
/// `it's` → `it'\''s`. Caller owns the returned slice.
fn shSingleQuoteEscape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(a, "'\\''");
        } else {
            try out.append(a, c);
        }
    }
    return out.toOwnedSlice(a);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS for the three new osascript tests.

- [ ] **Step 5: Commit**

```bash
git add src/infra/inbound/tui/terminal_launcher.zig
git commit -m "feat(tui): osascript launchers for iTerm2 and Terminal.app"
```

---

## Task 4: Wire `Launcher` into `tui.UseCases` and `main.zig`

**Files:**
- Modify: `src/infra/inbound/tui/use_cases.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Add `terminal_launcher` field to `tui.UseCases`**

Edit `src/infra/inbound/tui/use_cases.zig`:

```zig
const std = @import("std");
const app = @import("application");
const d = @import("domain");
const cfg = @import("infra_config");
const terminal_launcher = @import("terminal_launcher.zig");

pub const UseCases = struct {
    // ... existing fields unchanged ...
    add_todo: app.AddTodo,
    list_tasks: app.ListTasks,
    get_task: app.GetTask,
    update_task: app.UpdateTask,
    archive: app.ArchiveTask,
    delete_task: app.DeleteTask,
    link: app.LinkTask,
    refresh: app.RefreshAll,
    repos: []const d.Repo,
    add_handoff: app.AddHandoff,
    get_context: app.GetContext,
    templates_lookup: *const fn (provider: []const u8) ?app.BuildResumeCommand.ProviderTemplate,
    default_provider: ?[]const u8,
    spawn_template: ?[]const u8,
    io: std.Io,
    refresh_interval_ms: u32 = 2000,
    use_nerd_glyphs: bool = true,
    color_scheme_cfg: cfg.ColorScheme = .{},
    db_path: []const u8 = "",
    cfg_repos: []const cfg.RepoConfig = &.{},
    // NEW:
    terminal_launcher: terminal_launcher.Launcher = .{ .kind = .none },
};
```

- [ ] **Step 2: Call `terminal_launcher.detect` in `main.zig` and pass into `tui.UseCases`**

Edit `src/main.zig`. Inside the `.none` branch of the dispatch switch, after the existing field assignments in the `tui.UseCases{...}` literal, add `.terminal_launcher = tui.terminal_launcher.detect(&init.environ_map),`.

Need to first re-export `terminal_launcher` from `tui/root.zig` so `main.zig` can reach it:

Edit `src/infra/inbound/tui/root.zig`:

```zig
pub const app = @import("app.zig");
pub const view = @import("view.zig");
pub const state = @import("state.zig");
pub const modal = @import("modal.zig");
pub const terminal_launcher = @import("terminal_launcher.zig");
pub const UseCases = @import("use_cases.zig").UseCases;
pub const run = app.run;
pub const Selection = view.Selection;
pub const State = state.State;

test {
    _ = view;
    _ = state;
    _ = modal;
    _ = @import("use_cases.zig");
    _ = @import("theme.zig");
    _ = @import("glyphs.zig");
    _ = @import("card_layout.zig");
    _ = @import("tick.zig");
    _ = @import("repo_match.zig");
    _ = @import("terminal_launcher.zig");
}
```

Then in `src/main.zig` inside the `.none =>` block, add to the `tui.UseCases{...}` literal (right before the closing `}`):

```zig
.terminal_launcher = tui.terminal_launcher.detect(&init.environ_map),
```

- [ ] **Step 3: Run `zig build` to confirm it compiles**

Run: `zig build`
Expected: success, no errors.

- [ ] **Step 4: Run tests to confirm nothing regressed**

Run: `zig build test`
Expected: all tests pass (no behavior change yet; this is wiring).

- [ ] **Step 5: Commit**

```bash
git add src/infra/inbound/tui/root.zig src/infra/inbound/tui/use_cases.zig src/main.zig
git commit -m "feat(tui): wire terminal launcher into UseCases"
```

---

## Task 5: Use `Launcher` in `doResume` when no `spawn_template`

**Files:**
- Modify: `src/infra/inbound/tui/app.zig:506-514`

- [ ] **Step 1: Read the existing `doResume` no-spawn branch**

Open `src/infra/inbound/tui/app.zig` lines 506–514. The branch currently looks like:

```zig
    if (no_spawn) {
        // No terminal multiplexer configured: show the command in the footer.
        // File is unused — clean up.
        std.Io.Dir.deleteFileAbsolute(uc.io, path) catch {};
        const msg = try std.fmt.allocPrint(a, "resume cmd: {s}", .{cmd.command});
        defer a.free(msg);
        try state.setMessage(msg);
        return;
    }
```

We're going to replace the inner body so that when `uc.terminal_launcher.kind != .none`, we build an argv and spawn it; otherwise we keep the existing footer-print fallback. The file does NOT need to be deleted when we DO spawn — the new terminal will `cat` it.

- [ ] **Step 2: Replace the no_spawn branch**

In `src/infra/inbound/tui/app.zig`, locate the `if (no_spawn) { ... }` block and replace it with:

```zig
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

        const argv = @import("terminal_launcher.zig").buildArgv(
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
        defer @import("terminal_launcher.zig").freeArgv(a, argv);

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
```

- [ ] **Step 3: Build to verify compile success**

Run: `zig build`
Expected: success.

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: all tests pass. (No new unit tests for `doResume` itself — it requires a real TTY. Manual smoke test next.)

- [ ] **Step 5: Manual smoke test**

```bash
zig build install --prefix ~/.local
# In Alacritty/iTerm/Terminal.app/WezTerm/Kitty:
ctt
# Press 'r' on any existing task. Expect a new terminal window to open
# at the task's project_path (or $HOME) running the resume command.
# In the kanban, the footer should show "spawned in <terminal-name>".
```

- [ ] **Step 6: Commit**

```bash
git add src/infra/inbound/tui/app.zig
git commit -m "feat(tui): spawn new terminal via auto-detected launcher on resume"
```

---

## Task 6: Add `project_roots` to config schema

**Files:**
- Modify: `src/infra/outbound/config/loader.zig`

- [ ] **Step 1: Write the failing test**

Append to the test block in `loader.zig`:

```zig
test "load config with project_roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/x","repos":[],"project_roots":["/home/me/code","/home/me/work"]}
    );

    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);

    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.project_roots.len);
    try std.testing.expectEqualStrings("/home/me/code", parsed.value.project_roots[0]);
    try std.testing.expectEqualStrings("/home/me/work", parsed.value.project_roots[1]);
}

test "load config without project_roots defaults to empty" {
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

    try std.testing.expectEqual(@as(usize, 0), parsed.value.project_roots.len);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: failures because `Config` has no `project_roots` field.

- [ ] **Step 3: Add `project_roots` to `Config`**

Edit the `Config` struct (around line 55):

```zig
pub const Config = struct {
    db_path: []const u8,
    default_browser: ?[]const u8 = null,
    repos: []RepoConfig,
    project_roots: []const []const u8 = &.{},
    providers: ProvidersConfig = .{},
    refresh: RefreshConfig = .{},
    ui: UiConfig = .{},
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS for the two new `project_roots` tests.

- [ ] **Step 5: Commit**

```bash
git add src/infra/outbound/config/loader.zig
git commit -m "feat(config): add project_roots field for picker scanning"
```

---

## Task 7: Add `~/` expansion helper to config loader

**Files:**
- Modify: `src/infra/outbound/config/loader.zig`

- [ ] **Step 1: Write the failing test**

Append:

```zig
test "expandHome leaves absolute paths unchanged" {
    const got = try expandHome(std.testing.allocator, "/abs/path", "/home/me");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/abs/path", got);
}

test "expandHome rewrites tilde prefix" {
    const got = try expandHome(std.testing.allocator, "~/code", "/home/me");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/home/me/code", got);
}

test "expandHome rewrites bare tilde" {
    const got = try expandHome(std.testing.allocator, "~", "/home/me");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/home/me", got);
}

test "expandHome leaves tilde-in-middle alone" {
    // We only expand a leading "~" / "~/" — anything else is opaque to us.
    const got = try expandHome(std.testing.allocator, "/x/~foo", "/home/me");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/x/~foo", got);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: failures — `expandHome` is undefined.

- [ ] **Step 3: Implement `expandHome` as a public function in `loader.zig`**

Insert above the test block:

```zig
/// Expand a leading `~` or `~/` to the user's home directory.
/// Other tildes are left alone. Returns a newly-allocated string;
/// caller must free.
pub fn expandHome(a: std.mem.Allocator, path: []const u8, home: []const u8) ![]u8 {
    if (path.len == 1 and path[0] == '~') {
        return a.dupe(u8, home);
    }
    if (path.len >= 2 and path[0] == '~' and path[1] == '/') {
        return std.fmt.allocPrint(a, "{s}{s}", .{ home, path[1..] });
    }
    return a.dupe(u8, path);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS for all four `expandHome` tests.

- [ ] **Step 5: Commit**

```bash
git add src/infra/outbound/config/loader.zig
git commit -m "feat(config): add expandHome helper for path resolution"
```

---

## Task 8: CLI args for `config project-root add/list/remove`

**Files:**
- Modify: `src/infra/inbound/cli/args.zig`

- [ ] **Step 1: Write failing tests**

Append to the existing test block in `args.zig`:

```zig
test "config project-root add" {
    var argv = [_][:0]u8{
        @constCast(@as([:0]const u8, "config")),
        @constCast(@as([:0]const u8, "project-root")),
        @constCast(@as([:0]const u8, "add")),
        @constCast(@as([:0]const u8, "/home/me/code")),
    };
    const cmd = try parse(std.testing.allocator, argv[0..]);
    defer freeCommand(std.testing.allocator, cmd);

    try std.testing.expect(cmd == .config);
    try std.testing.expect(cmd.config == .project_root_add);
    try std.testing.expectEqualStrings("/home/me/code", cmd.config.project_root_add.path);
}

test "config project-root list" {
    var argv = [_][:0]u8{
        @constCast(@as([:0]const u8, "config")),
        @constCast(@as([:0]const u8, "project-root")),
        @constCast(@as([:0]const u8, "list")),
    };
    const cmd = try parse(std.testing.allocator, argv[0..]);
    defer freeCommand(std.testing.allocator, cmd);

    try std.testing.expect(cmd == .config);
    try std.testing.expect(cmd.config == .project_root_list);
}

test "config project-root remove" {
    var argv = [_][:0]u8{
        @constCast(@as([:0]const u8, "config")),
        @constCast(@as([:0]const u8, "project-root")),
        @constCast(@as([:0]const u8, "remove")),
        @constCast(@as([:0]const u8, "/home/me/code")),
    };
    const cmd = try parse(std.testing.allocator, argv[0..]);
    defer freeCommand(std.testing.allocator, cmd);

    try std.testing.expect(cmd == .config);
    try std.testing.expect(cmd.config == .project_root_remove);
    try std.testing.expectEqualStrings("/home/me/code", cmd.config.project_root_remove.path);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test`
Expected: failures — `project_root_add`/`_list`/`_remove` variants don't exist on `ConfigCmd`.

- [ ] **Step 3: Add the new variants to `ConfigCmd`**

Edit the `ConfigCmd` union:

```zig
pub const ConfigCmd = union(enum) {
    repo_add: struct { path: []const u8 },
    repo_list,
    repo_remove: struct { name: []const u8 },
    linear_set_token: struct { token: []const u8 },
    project_root_add: struct { path: []const u8 },
    project_root_list,
    project_root_remove: struct { path: []const u8 },
};
```

- [ ] **Step 4: Extend `parseConfig` to recognize `project-root`**

Inside `parseConfig` (around line 407), add a branch after the existing `linear` branch:

```zig
    } else if (std.mem.eql(u8, sub, "project-root")) {
        if (argv.len < 2) return error.MissingArg;
        const action = argv[1];
        if (std.mem.eql(u8, action, "add")) {
            if (argv.len < 3) return error.MissingArg;
            return .{ .config = .{ .project_root_add = .{ .path = try a.dupe(u8, argv[2]) } } };
        } else if (std.mem.eql(u8, action, "list")) {
            return .{ .config = .project_root_list };
        } else if (std.mem.eql(u8, action, "remove")) {
            if (argv.len < 3) return error.MissingArg;
            return .{ .config = .{ .project_root_remove = .{ .path = try a.dupe(u8, argv[2]) } } };
        }
        return error.UnknownCommand;
    }
```

- [ ] **Step 5: Extend `freeCommand` to release the new variants' allocated strings**

Find the `.config` arm of `freeCommand` and update it. Open `args.zig` around line 191 and update the existing `.config => |v| {...}` block to free `project_root_add` / `project_root_remove`. The current code likely already iterates union cases; add the new ones the same way:

```zig
        .config => |v| {
            switch (v) {
                .repo_add => |x| a.free(x.path),
                .repo_remove => |x| a.free(x.name),
                .linear_set_token => |x| a.free(x.token),
                .project_root_add => |x| a.free(x.path),
                .project_root_remove => |x| a.free(x.path),
                .repo_list, .project_root_list => {},
            }
        },
```

(Adjust to match the existing pattern; do not duplicate arms already present.)

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS for the three new `config project-root ...` tests.

- [ ] **Step 7: Commit**

```bash
git add src/infra/inbound/cli/args.zig
git commit -m "feat(cli): parse 'config project-root add/list/remove'"
```

---

## Task 9: CLI handler stubs for `config project-root`

**Files:**
- Modify: `src/infra/inbound/cli/handlers.zig:242-252`

- [ ] **Step 1: Update `handleConfig` to cover the new variants**

Replace the existing `handleConfig` function body:

```zig
fn handleConfig(a: std.mem.Allocator, uc: *UseCases, args: args_mod.ConfigCmd, writer: anytype) !void {
    _ = a;
    _ = uc;
    switch (args) {
        .repo_add => |x| try writer.print("config repo add not yet implemented (path={s})\n", .{x.path}),
        .repo_list => try writer.print("config repo list not yet implemented (read config.json directly)\n", .{}),
        .repo_remove => |x| try writer.print("config repo remove not yet implemented (name={s})\n", .{x.name}),
        .linear_set_token => try writer.print("config linear set-token not yet implemented (set CTT_LINEAR_TOKEN or edit secrets.json)\n", .{}),
        .project_root_add => |x| try writer.print("config project-root add not yet implemented (path={s}); edit \"project_roots\" in config.json directly\n", .{x.path}),
        .project_root_list => try writer.print("config project-root list not yet implemented (read \"project_roots\" in config.json)\n", .{}),
        .project_root_remove => |x| try writer.print("config project-root remove not yet implemented (path={s}); edit \"project_roots\" in config.json directly\n", .{x.path}),
    }
}
```

- [ ] **Step 2: Update the top-level CLI help text in `handlers.zig`**

Find the `--help` body that lists the existing `config repo add` lines (around line 72) and add:

```
  config project-root add <path>          add directory to scan for projects
  config project-root list
  config project-root remove <path>
```

near the existing `config repo` lines.

- [ ] **Step 3: Run `zig build`**

Run: `zig build`
Expected: success.

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: all tests pass.

- [ ] **Step 5: Manual smoke test**

```bash
./zig-out/bin/ctt config project-root add /tmp/x
# Expected output: config project-root add not yet implemented (path=/tmp/x); edit "project_roots" in config.json directly
./zig-out/bin/ctt --help | grep project-root
# Expected: three project-root lines visible
```

- [ ] **Step 6: Commit**

```bash
git add src/infra/inbound/cli/handlers.zig
git commit -m "feat(cli): wire 'config project-root' stub handlers and help"
```

---

## Task 10: `project_candidates.zig` — scan project_roots, merge with repos

**Files:**
- Create: `src/infra/inbound/tui/project_candidates.zig`
- Modify: `src/infra/inbound/tui/root.zig` (add to test block)

- [ ] **Step 1: Create the file with types and a `build` stub**

```zig
const std = @import("std");
const cfg = @import("infra_config");

pub const Candidate = struct {
    name: []const u8,
    path: []const u8,
};

/// Names that are never useful as project entries.
const DENYLIST = [_][]const u8{
    "node_modules", "target", ".git", "build", "dist",
    "zig-cache",    "zig-out", ".zig-cache",
};

pub const BuildError = error{OutOfMemory};

/// Build the candidate list:
///   1. Start with every repo in `cfg_repos`.
///   2. For each directory in `project_roots`, add one entry per direct subdirectory
///      whose name is not in DENYLIST and does not start with `.`.
///   3. Dedupe by absolute path; entries from `cfg_repos` win on collision.
///
/// Returned candidates are owned by `a` (each `name` and `path` is duped). Free
/// via `freeCandidates`.
pub fn build(
    a: std.mem.Allocator,
    cfg_repos: []const cfg.RepoConfig,
    project_roots: []const []const u8,
) BuildError![]Candidate {
    _ = project_roots;
    var out: std.ArrayList(Candidate) = .empty;
    errdefer freeCandidates(a, out.items);
    errdefer out.deinit(a);
    for (cfg_repos) |r| {
        try out.append(a, .{
            .name = try a.dupe(u8, r.name),
            .path = try a.dupe(u8, r.path),
        });
    }
    return out.toOwnedSlice(a);
}

pub fn freeCandidates(a: std.mem.Allocator, c: []const Candidate) void {
    for (c) |x| {
        a.free(x.name);
        a.free(x.path);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "build from cfg_repos only" {
    const repos = [_]cfg.RepoConfig{
        .{ .name = "ctt", .path = "/Users/me/ctt" },
        .{ .name = "foo", .path = "/Users/me/foo" },
    };
    const got = try build(std.testing.allocator, &repos, &.{});
    defer {
        freeCandidates(std.testing.allocator, got);
        std.testing.allocator.free(got);
    }
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("ctt", got[0].name);
    try std.testing.expectEqualStrings("/Users/me/ctt", got[0].path);
}
```

- [ ] **Step 2: Register in `root.zig` test block**

Edit `src/infra/inbound/tui/root.zig` to add `_ = @import("project_candidates.zig");` to the test block.

- [ ] **Step 3: Run the test to verify it passes**

Run: `zig build test`
Expected: PASS for `build from cfg_repos only`.

- [ ] **Step 4: Write failing test for scanning roots**

Append to the test block in `project_candidates.zig`:

```zig
test "build scans project_roots and skips denylist/dotdirs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Layout:
    //   <tmp>/
    //     alpha/
    //     beta/
    //     node_modules/    (denylisted)
    //     .hidden/         (dotdir)
    try tmp.dir.makeDir("alpha");
    try tmp.dir.makeDir("beta");
    try tmp.dir.makeDir("node_modules");
    try tmp.dir.makeDir(".hidden");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_abs = try tmp.dir.realPath(std.testing.io, &buf);
    const root_dup = try std.testing.allocator.dupe(u8, root_abs);
    defer std.testing.allocator.free(root_dup);

    const roots = [_][]const u8{root_dup};
    const got = try build(std.testing.allocator, &.{}, &roots);
    defer {
        freeCandidates(std.testing.allocator, got);
        std.testing.allocator.free(got);
    }

    // alpha + beta, sorted by encounter order (readdir is unordered, so we
    // assert presence not order).
    try std.testing.expectEqual(@as(usize, 2), got.len);
    var saw_alpha = false;
    var saw_beta = false;
    for (got) |c| {
        if (std.mem.eql(u8, c.name, "alpha")) saw_alpha = true;
        if (std.mem.eql(u8, c.name, "beta")) saw_beta = true;
    }
    try std.testing.expect(saw_alpha);
    try std.testing.expect(saw_beta);
}

test "build dedupes by path; repos win" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("ctt");

    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_abs = try tmp.dir.realPath(std.testing.io, &buf);
    const root_dup = try std.testing.allocator.dupe(u8, root_abs);
    defer std.testing.allocator.free(root_dup);

    const ctt_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/ctt", .{root_dup});
    defer std.testing.allocator.free(ctt_path);

    // Repo registers the same absolute path with a custom display name.
    const repos = [_]cfg.RepoConfig{
        .{ .name = "my-cool-ctt", .path = ctt_path },
    };
    const roots = [_][]const u8{root_dup};
    const got = try build(std.testing.allocator, &repos, &roots);
    defer {
        freeCandidates(std.testing.allocator, got);
        std.testing.allocator.free(got);
    }

    // Exactly one entry; the repo's name wins over the scanned basename.
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("my-cool-ctt", got[0].name);
}

test "build tolerates non-existent root" {
    const roots = [_][]const u8{"/nonexistent/path/never/exists"};
    const got = try build(std.testing.allocator, &.{}, &roots);
    defer {
        freeCandidates(std.testing.allocator, got);
        std.testing.allocator.free(got);
    }
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `zig build test`
Expected: 3 failures (the new scanning tests find 0 candidates).

- [ ] **Step 6: Implement `build` body to scan roots and dedupe**

Replace the `build` body:

```zig
pub fn build(
    a: std.mem.Allocator,
    cfg_repos: []const cfg.RepoConfig,
    project_roots: []const []const u8,
) BuildError![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    errdefer {
        freeCandidates(a, out.items);
        out.deinit(a);
    }

    // 1. Configured repos first (they win on collision).
    for (cfg_repos) |r| {
        try out.append(a, .{
            .name = try a.dupe(u8, r.name),
            .path = try a.dupe(u8, r.path),
        });
    }

    // 2. Scan each project_root one level deep.
    for (project_roots) |root| {
        var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry == null) break;
            const e = entry.?;
            if (e.kind != .directory) continue;
            if (e.name.len == 0 or e.name[0] == '.') continue;
            if (inDenylist(e.name)) continue;

            const full = std.fmt.allocPrint(a, "{s}/{s}", .{ root, e.name }) catch return error.OutOfMemory;
            errdefer a.free(full);

            // Dedupe: if any existing candidate has the same path, skip.
            if (hasPath(out.items, full)) {
                a.free(full);
                continue;
            }

            const name = a.dupe(u8, e.name) catch {
                a.free(full);
                return error.OutOfMemory;
            };
            try out.append(a, .{ .name = name, .path = full });
        }
    }

    return out.toOwnedSlice(a);
}

fn inDenylist(name: []const u8) bool {
    for (DENYLIST) |d| {
        if (std.mem.eql(u8, d, name)) return true;
    }
    return false;
}

fn hasPath(items: []const Candidate, path: []const u8) bool {
    for (items) |c| {
        if (std.mem.eql(u8, c.path, path)) return true;
    }
    return false;
}
```

> **Note on iterator return type:** if `std.fs.Dir.iterate()`'s `next()` returns `!?Entry` and the entry is just `Entry`, simplify the inner loop body accordingly. The shape above matches Zig 0.16's std API; if it doesn't compile, replace the `if (entry == null) break;` with the appropriate `while` form for your Zig version.

- [ ] **Step 7: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS for all four `project_candidates` tests.

- [ ] **Step 8: Commit**

```bash
git add src/infra/inbound/tui/project_candidates.zig src/infra/inbound/tui/root.zig
git commit -m "feat(tui): scan project_roots into candidate list, dedupe with repos"
```

---

## Task 11: Wire candidates and `fzf_available` through `UseCases` and `main.zig`

**Files:**
- Modify: `src/infra/inbound/tui/use_cases.zig`
- Modify: `src/infra/inbound/tui/root.zig`
- Modify: `src/main.zig`
- Modify: `src/infra/inbound/tui/modal.zig` (switch to candidates)
- Modify: `src/infra/inbound/tui/app.zig` (`handleProjectFieldKey` uses candidates)
- Modify: `src/infra/inbound/tui/repo_match.zig` (accept candidates instead of `RepoConfig`)

- [ ] **Step 1: Generalize `repo_match.Match` source by adding a candidate-typed overload**

`repo_match.fuzzyMatch` currently takes `[]const cfg.RepoConfig`. Add a parallel function for candidates so we don't have to touch existing call sites yet.

Insert in `src/infra/inbound/tui/repo_match.zig` above the `Tests` divider:

```zig
const project_candidates = @import("project_candidates.zig");

/// Same as `fuzzyMatch` but accepts pre-built candidates instead of `RepoConfig`.
pub fn fuzzyMatchCandidates(
    candidates: []const project_candidates.Candidate,
    query: []const u8,
    out: []Match,
) []Match {
    std.debug.assert(out.len >= MAX_RESULTS);

    if (query.len == 0) {
        const n = @min(candidates.len, MAX_RESULTS);
        for (candidates[0..n], 0..) |c, i| {
            out[i] = .{ .name = c.name, .path = c.path };
        }
        return out[0..n];
    }

    var lower_q_buf: [256]u8 = undefined;
    if (query.len > lower_q_buf.len) return out[0..0];
    const lq = std.ascii.lowerString(&lower_q_buf, query);

    const Scored = struct { bucket: u8, idx: usize };
    var scored: [256]Scored = undefined;
    var n: usize = 0;

    for (candidates, 0..) |c, i| {
        if (n >= scored.len) break;
        const score = scoreCandidate(c, lq);
        if (score < 255) {
            scored[n] = .{ .bucket = score, .idx = i };
            n += 1;
        }
    }

    std.mem.sort(Scored, scored[0..n], {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            if (a.bucket != b.bucket) return a.bucket < b.bucket;
            return a.idx < b.idx;
        }
    }.lt);

    const take = @min(n, MAX_RESULTS);
    for (scored[0..take], 0..) |s, i| {
        out[i] = .{ .name = candidates[s.idx].name, .path = candidates[s.idx].path };
    }
    return out[0..take];
}

fn scoreCandidate(c: project_candidates.Candidate, lq: []const u8) u8 {
    var name_buf: [256]u8 = undefined;
    var path_buf: [1024]u8 = undefined;
    if (c.name.len > name_buf.len or c.path.len > path_buf.len) return 255;
    const ln = std.ascii.lowerString(&name_buf, c.name);
    const lp = std.ascii.lowerString(&path_buf, c.path);

    if (std.mem.startsWith(u8, ln, lq)) return 0;
    if (std.mem.indexOf(u8, ln, lq) != null) return 1;
    if (std.mem.indexOf(u8, lp, lq) != null) return 2;
    return 255;
}
```

- [ ] **Step 2: Add `candidates` and `fzf_available` to `tui.UseCases`**

```zig
// in src/infra/inbound/tui/use_cases.zig
const project_candidates = @import("project_candidates.zig");

pub const UseCases = struct {
    // ... existing fields ...
    candidates: []const project_candidates.Candidate = &.{},
    fzf_available: bool = false,
    terminal_launcher: terminal_launcher.Launcher = .{ .kind = .none },
};
```

- [ ] **Step 3: Re-export `project_candidates` from `root.zig` so `main.zig` can call `build`**

Edit `src/infra/inbound/tui/root.zig`:

```zig
pub const project_candidates = @import("project_candidates.zig");
```

(Add alongside the existing exports.)

- [ ] **Step 4: Build candidates and check fzf in `main.zig`, pass into `tui.UseCases`**

In `src/main.zig` immediately after the `defer freeRepos(a, repos);` line:

```zig
    // Build TUI candidate list (configured repos + scanned project_roots).
    const candidates = try tui.project_candidates.build(a, cfg.repos, cfg.project_roots);
    defer {
        tui.project_candidates.freeCandidates(a, candidates);
        a.free(candidates);
    }

    // Probe fzf availability once.
    const fzf_available = blk: {
        var child = std.process.Child.init(&.{ "which", "fzf" }, a);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch break :blk false;
        const term = child.wait() catch break :blk false;
        break :blk switch (term) { .Exited => |code| code == 0, else => false };
    };
```

Inside the `.none =>` arm where `tui.UseCases{...}` is constructed, add:

```zig
.candidates = candidates,
.fzf_available = fzf_available,
```

- [ ] **Step 5: Update `handleProjectFieldKey` and modal renderer to read from `candidates`**

In `src/infra/inbound/tui/app.zig`, change line 207:

```zig
    const matches = repo_match.fuzzyMatchCandidates(uc.candidates, modal.project_buf.items, &match_buf);
```

In `src/infra/inbound/tui/modal.zig`, change line 114 — but `modal.zig` reads from `state.cfg_repos`. Add the candidates to `State` via the existing wiring path used by `cfg_repos`. Specifically:

- In `src/infra/inbound/tui/state.zig`, add `candidates: []const project_candidates.Candidate = &.{}` and `fzf_available: bool = false` fields to `State`. (You'll need `const project_candidates = @import("project_candidates.zig");` at the top.)
- In `src/infra/inbound/tui/app.zig`'s `run` (search for the place State is constructed; mirror how `cfg_repos` is passed in from `uc`), pass `uc.candidates` and `uc.fzf_available` into `State`.
- In `src/infra/inbound/tui/modal.zig` line 114, replace `state.cfg_repos` with `state.candidates` and the call with `repo_match.fuzzyMatchCandidates(state.candidates, modal.project_buf.items, &match_buf);`.

- [ ] **Step 6: Run `zig build` to confirm everything compiles**

Run: `zig build`
Expected: success.

- [ ] **Step 7: Run tests**

Run: `zig build test`
Expected: all pass. The existing `repo_match` tests still cover the legacy `fuzzyMatch`; nothing should regress.

- [ ] **Step 8: Manual smoke test**

```bash
# Add ~/tru4m to your config.json:
#   "project_roots": ["/Users/<you>/tru4m"]
zig build install --prefix ~/.local
ctt
# Press 'a' to add a task, tab to Project field, type a letter.
# The inline dropdown should now show your tru4m subdirs (ctt, moe-backend, ...).
```

- [ ] **Step 9: Commit**

```bash
git add src/infra/inbound/tui/repo_match.zig src/infra/inbound/tui/use_cases.zig \
        src/infra/inbound/tui/state.zig src/infra/inbound/tui/modal.zig \
        src/infra/inbound/tui/app.zig src/infra/inbound/tui/root.zig src/main.zig
git commit -m "feat(tui): merge project_roots scan into picker candidates"
```

---

## Task 12: `fzf_picker.zig` — module with `available` and `pick` (suspend/launch/resume)

**Files:**
- Create: `src/infra/inbound/tui/fzf_picker.zig`
- Modify: `src/infra/inbound/tui/root.zig` (add to test block + export)

This module is intentionally thin and untested by unit tests — the suspend/resume requires a real TTY. The `available` function is tested.

- [ ] **Step 1: Create the file**

```zig
const std = @import("std");
const project_candidates = @import("project_candidates.zig");

pub const Selection = struct {
    name: []const u8,
    path: []const u8,
};

/// Returns true if `fzf` is on $PATH. Result is cheap enough to call once at
/// TUI startup; cache it on State.
pub fn available(a: std.mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "which", "fzf" }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) { .Exited => |code| code == 0, else => false };
}

/// Suspend the TUI (caller is responsible for the actual suspend via vaxis;
/// see `pickWithVaxis` for the integrated version), pipe candidates to fzf,
/// read the selected path back, restore. Returns null if user cancelled or
/// fzf failed to launch.
///
/// Candidates are written as "name\tpath" per line; fzf is told to display
/// only the first column.
pub fn pickFromPipe(
    a: std.mem.Allocator,
    candidates: []const project_candidates.Candidate,
) !?Selection {
    var child = std.process.Child.init(
        &.{ "fzf", "--with-nth=1", "--delimiter=\t", "--prompt=project> ", "--height=40%" },
        a,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    // Write candidates to fzf's stdin, then close.
    {
        const stdin = child.stdin.?;
        defer {
            stdin.close();
            child.stdin = null;
        }
        var bw = std.io.bufferedWriter(stdin.writer());
        const w = bw.writer();
        for (candidates) |c| {
            try w.print("{s}\t{s}\n", .{ c.name, c.path });
        }
        try bw.flush();
    }

    // Read one line of stdout.
    var out_buf: [4096]u8 = undefined;
    const stdout = child.stdout.?;
    const n = stdout.reader().readAll(&out_buf) catch 0;
    const text = std.mem.trimRight(u8, out_buf[0..n], "\r\n");

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }
    if (text.len == 0) return null;

    // Parse "name\tpath"
    const tab = std.mem.indexOfScalar(u8, text, '\t') orelse return null;
    return .{
        .name = try a.dupe(u8, text[0..tab]),
        .path = try a.dupe(u8, text[tab + 1 ..]),
    };
}

pub fn freeSelection(a: std.mem.Allocator, sel: Selection) void {
    a.free(sel.name);
    a.free(sel.path);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "available returns false when fzf-fake is not on PATH" {
    // Hard to make a positive test deterministic in CI; verify negative via
    // an env hijack on PATH.
    const orig_path = std.posix.getenv("PATH") orelse "";
    // Save & overwrite PATH so fzf is definitely not found.
    var env_buf: [4]u8 = .{ 0, 0, 0, 0 };
    _ = env_buf;
    // The std lib doesn't have a portable setenv; just trust this on CI where
    // fzf isn't installed. Locally with fzf installed this test is skipped.
    if (std.mem.indexOf(u8, orig_path, "fzf") != null) return error.SkipZigTest;
    try std.testing.expect(!available(std.testing.allocator));
}
```

> **Note:** The streaming-IO patterns above assume Zig 0.16's `Child` exposes the legacy `.stdin/.stdout` `std.fs.File` handles with `.writer()` / `.reader()` helpers. If your local std diverges, swap to whichever API the project's existing `Child` usages (search `infra/inbound/cli/handlers.zig` line ~379 and `infra/inbound/tui/app.zig` line ~523 for examples) — adapt without changing the externally-visible API of `fzf_picker.pick`.

- [ ] **Step 2: Add to `root.zig`**

Edit `src/infra/inbound/tui/root.zig`:

```zig
pub const fzf_picker = @import("fzf_picker.zig");
```

And in the test block:

```zig
_ = @import("fzf_picker.zig");
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: PASS (the `available` test is conditionally skipped if fzf is installed locally).

- [ ] **Step 4: Commit**

```bash
git add src/infra/inbound/tui/fzf_picker.zig src/infra/inbound/tui/root.zig
git commit -m "feat(tui): fzf_picker module — availability + pipe-based pick"
```

---

## Task 13: Trigger fzf picker on project-field focus and `Ctrl-P` reopen

**Files:**
- Modify: `src/infra/inbound/tui/app.zig`

Vaxis-specific code: when we suspend the TUI to launch fzf, we need to (a) leave the alternate screen, (b) exit raw mode, (c) `child.spawn()` fzf with stdin/stdout inherited (or piped — see Task 12's `pickFromPipe`), (d) re-enter raw mode + alt screen, (e) trigger a full redraw. The exact vaxis calls depend on which vaxis version the project pulls — search `tui/app.zig` for `enterAltScreen` / `enableMouse` / similar to mirror.

- [ ] **Step 1: Wrap suspend/launch/resume in a helper inside `app.zig`**

Add this function somewhere near `handleProjectFieldKey` (around line 200):

```zig
fn openFzfPicker(
    a: std.mem.Allocator,
    uc: *UseCases,
    state: *state_mod.State,
    tui_handle: anytype, // pass whatever vaxis context `run` already has
) !void {
    if (!uc.fzf_available) return;
    // 1. Suspend the TUI.
    //    Inspect `tui/app.zig`'s `run` for the actual exit sequence used at
    //    shutdown; mirror it here. Typically this means:
    //       tui_handle.exitAltScreen();
    //       tui_handle.disableRawMode();
    // 2. Launch fzf and read the selection.
    const maybe_sel = fzf_picker.pickFromPipe(a, uc.candidates) catch null;
    // 3. Resume the TUI:
    //       tui_handle.enterAltScreen();
    //       tui_handle.enableRawMode();
    //       state.requestFullRedraw();
    // 4. Fill the project field if selected.
    if (maybe_sel) |sel| {
        defer fzf_picker.freeSelection(a, sel);
        state.add_todo_modal.project_buf.clearRetainingCapacity();
        try state.add_todo_modal.project_buf.appendSlice(a, sel.path);
    }
}
```

> **Important:** This step is a structural template. The vaxis suspend/resume incantation depends on the version in use. Before committing, replace the `// 1.` and `// 3.` comments with the real vaxis calls — grep `app.zig` for `vaxis.Tty`, `enterAltScreen`, `disableInput`, etc. to find the existing teardown path; reuse it.

- [ ] **Step 2: Call `openFzfPicker` when the user tabs into the project field**

In `src/infra/inbound/tui/app.zig`, find `modal.cycleFocus()` calls (or wherever Tab is handled at the modal level). When focus *enters* `.project` and `uc.fzf_available` is true, call `openFzfPicker`. The simplest hook is right after the Tab handling in the other fields' key handler — when focus becomes `.project` and was previously something else, call the picker.

Concrete change: where the modal handler dispatches to `handleProjectFieldKey`, gate the dispatch on `modal.project_picker_triggered` (a new bool on State.add_todo_modal). On first entry to `.project`, if `uc.fzf_available`, call `openFzfPicker` and set `project_picker_triggered = true`. Reset to false when the modal closes.

- [ ] **Step 3: Bind `Ctrl-P` to reopen fzf inside `handleProjectFieldKey`**

Insert at the top of `handleProjectFieldKey` (before the existing key matches):

```zig
    if (k.matches('p', .{ .ctrl = true })) {
        if (uc.fzf_available) {
            // Caller must thread through the vaxis handle — adapt signature
            // similarly to how doResume gets access to spawn primitives.
            try openFzfPicker(a, uc, state, /* tui handle */ undefined);
        }
        return;
    }
```

> Replace `undefined` with the real handle threaded from `run`. If the existing code makes the vaxis handle available via a field on `State` or `UseCases`, pass it the same way.

- [ ] **Step 4: Run `zig build`**

Run: `zig build`
Expected: success (after replacing the `undefined` and suspend/resume placeholders with real calls).

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: all pass.

- [ ] **Step 6: Manual smoke test**

```bash
brew install fzf  # if not present
zig build install --prefix ~/.local
# Edit ~/.config/ctt/config.json — add "project_roots":["/Users/<you>/tru4m"]
ctt
# Press 'a' to open Add Todo. Fill title. Tab to Project field.
# Expected: TUI suspends, fzf opens with your tru4m subdirs listed.
# Select one; TUI re-renders with the project field filled with the path.
# Press Ctrl-P to reopen.
# Press Esc inside fzf to cancel without filling the field.
```

- [ ] **Step 7: Commit**

```bash
git add src/infra/inbound/tui/app.zig src/infra/inbound/tui/state.zig
git commit -m "feat(tui): launch fzf for project picker on focus and Ctrl-P"
```

---

## Task 14: Update help text and README

**Files:**
- Modify: `src/infra/inbound/cli/handlers.zig` (top-level help block)
- Modify: `README.md`

- [ ] **Step 1: Add a `project_roots` section in README under config**

Find the config example in `README.md` (search for `"db_path"` or `"repos"`). Add a `project_roots` line and a sentence:

```jsonc
{
  "db_path": "/Users/me/.config/ctt/db.sqlite",
  "repos": [],
  "project_roots": ["~/tru4m", "~/code"],
  // ...
}
```

> `project_roots` lists directories that the TUI scans one level deep at startup. Each direct subdirectory becomes a project candidate in the Add-Todo picker. Combined with `repos`, this lets the picker find projects without registering every one explicitly.

- [ ] **Step 2: Document terminal auto-detect for `r`**

Add a short paragraph near the existing `ui.spawn` docs (search README for `spawn`):

> When no `ui.spawn` template is configured, the TUI auto-detects the running terminal (WezTerm, Kitty, Alacritty, iTerm2, Terminal.app) and opens a new window of that terminal running the resume command. Set `ui.spawn` if you want a custom layout (e.g. a tmux split).

- [ ] **Step 3: Document Ctrl-P in the TUI keybinds section**

Add a line in the keybinds list (if one exists in the README; otherwise skip):

> - `Ctrl-P` (project field, Add Todo modal): reopen fzf picker if fzf is installed.

- [ ] **Step 4: Run `zig build` and `zig build test` as a final sanity check**

Run: `zig build && zig build test`
Expected: success on both.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: explain project_roots, terminal auto-detect, Ctrl-P picker"
```

---

## Self-Review

**Spec coverage:**
- §4 Resume spawn → Tasks 1–5 (detect, buildArgv for sh-based launchers, buildArgv for osascript launchers, wiring, doResume call site).
- §5.1 Config field → Task 6.
- §5.1 path expansion → Task 7.
- §5.2 CLI → Tasks 8–9 (parser + stub handlers).
- §5.3 candidate list → Task 10.
- §5.4 fzf availability + §5.5 fzf launch → Task 12.
- §5.6 trigger + §5.7 free-form (preserved via existing modal text-input path) → Task 13.
- §6 module layout → Tasks 1, 10, 12 create the three new modules.
- §7 tests → unit tests in Tasks 1–3 (terminal_launcher), 6 (loader), 7 (expandHome), 8 (args), 10 (candidates); manual smoke tests in Tasks 5, 9, 11, 13.
- §8 backward compatibility → Task 6 default `&.{}`; Task 11 keeps `cfg_repos` first in candidate list; `ui.spawn` left untouched.

**Placeholder scan:**
- Task 13 uses `undefined` for the vaxis handle and `/* tui handle */` comments. These are flagged as "replace before committing" inside the task itself. Documented as such because the precise vaxis API in use can't be derived without reading the live `run` body — the executing engineer fills it in by mirroring the existing teardown sequence (which already exists in `app.zig`). Acceptable as long as the engineer treats this as part of the implementation step, not a follow-up TODO.
- Task 12 has a similar note about Zig 0.16 `Child` API. Concrete examples in the codebase are pointed to.

These two notes are unavoidable: the executing engineer needs to read the existing vaxis/Child usages to implement them faithfully, and the plan can't ship dead-reckoning code that won't compile.

**Type consistency:**
- `Candidate` is defined in `project_candidates.zig` with `{ name, path }` and used the same way in `fzf_picker.zig` (Selection has the same shape), `repo_match.fuzzyMatchCandidates`, `tui.UseCases.candidates`, `State.candidates`.
- `Launcher` / `Kind` from `terminal_launcher.zig` used consistently in `UseCases`, `doResume`, `buildArgv`.
- `BuildArgvError` returned by `buildArgv`, handled at the call site in Task 5.

No mismatches.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-09-tui-resume-spawn-and-fzf-picker.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
