# ctt — TUI Resume Spawn (Auto-Detect Terminal) & fzf Project Picker (Design)

**Date:** 2026-06-09
**Status:** Approved design, not yet implemented
**Builds on:** `2026-06-03-ctt-handoff-resume-design.md`, `2026-06-03-ctt-project-picker-design.md`

## 1. Overview

Two TUI rough edges, fixed together:

1. **Resume (`r`) doesn't actually launch anything when no `ui.spawn` template is configured.** The current TUI prints the resume command in the footer as a "copy-paste fallback." For users without a configured multiplexer wrapper that's the entire experience — they see a command but no Claude session opens. The fix: auto-detect the running terminal emulator from environment variables and build a per-terminal launch command that opens a new window. `ui.spawn` config still overrides if set.

2. **The project picker fuzzy-matches only against repos in `cfg.repos`.** For a user with `repos: []` (the default), the picker is empty — there's no way to discover projects on disk. The fix: introduce a `project_roots` config field, scan one level deep into each root, and use `fzf` (the binary) as the primary picker over the combined candidate list. If `fzf` is not installed, fall back to the existing in-TUI inline dropdown over the same list.

Both changes are scoped to the TUI inbound adapter and the config schema. Domain and other adapters are untouched.

## 2. Goals

- Pressing `r` on a task in the TUI opens a real Claude session in a real new terminal window, with zero config, for users of common macOS terminals (Alacritty, WezTerm, iTerm2, Terminal.app, Kitty).
- The new window's cwd is the task's `project_path` (or `$HOME` if unset).
- Existing `ui.spawn` config keeps working — it overrides auto-detection.
- The project picker offers a useful candidate list on first launch, without requiring the user to run `ctt config repo add` for every repo.
- `fzf` is the primary picker when available; the existing inline dropdown is the fallback so the feature degrades gracefully.
- No regression for users who already have `ui.spawn` set or have manually registered repos via `ctt config repo add`.

## 3. Non-goals (v1)

- Linux/Windows terminal detection. macOS only for v1; we can extend later (gnome-terminal, konsole, xterm, foot, etc.).
- Recursive filesystem walk for project discovery. We scan exactly one level under each configured root.
- Caching scan results across runs. The scan is cheap (a handful of `readdir`s on small directories) and runs once at TUI startup.
- Watching `project_roots` for changes during a TUI session. The candidate list is snapshotted at startup.
- A picker for editing an existing task's project. The picker only fires when adding a task.
- Replacing the inline picker with fzf for users who already have it working — they pay zero cost for the new path; the suspend/launch is only triggered when fzf is available and the user has tabbed into the project field.
- New domain entities or ports. Nothing in this design crosses into `src/domain/` or `src/application/`.

## 4. Resume spawn: auto-detect terminal

### 4.1 Detection

A new module `src/infra/inbound/tui/terminal_launcher.zig` exposes:

```zig
pub const Launcher = struct {
    /// One of: .wezterm, .kitty, .alacritty, .iterm2, .terminal_app, .none.
    /// Determined once at TUI startup by inspecting the environment.
    kind: Kind,
};

pub fn detect(env: *const std.process.EnvMap) Launcher;

/// Builds the argv for `std.process.spawn` that opens a new terminal window
/// running `cmd` with `cwd`. Returned slice is allocator-owned; caller frees.
pub fn buildArgv(
    a: std.mem.Allocator,
    launcher: Launcher,
    cwd: []const u8,
    cmd: []const u8,
) ![]const []const u8;
```

`detect` returns the first matching kind in priority order:

| Priority | Env var present                                    | Kind            |
| -------- | -------------------------------------------------- | --------------- |
| 1        | `WEZTERM_EXECUTABLE` or `WEZTERM_PANE`             | `.wezterm`      |
| 2        | `KITTY_WINDOW_ID`                                  | `.kitty`        |
| 3        | `ALACRITTY_LOG` or `ALACRITTY_SOCKET`              | `.alacritty`    |
| 4        | `TERM_PROGRAM == "iTerm.app"`                      | `.iterm2`       |
| 5        | `TERM_PROGRAM == "Apple_Terminal"`                 | `.terminal_app` |
| —        | none of the above                                  | `.none`         |

### 4.2 Launch templates

`buildArgv` builds the argv per kind. `cwd` is always quoted via shell single-quote escaping; `cmd` is passed as the body of a `/bin/sh -c` invocation by the terminal:

- **WezTerm**: `wezterm start --cwd <cwd> -- /bin/sh -c <cmd>`
- **Alacritty**: `alacritty --working-directory <cwd> -e /bin/sh -c <cmd>`
- **Kitty**: `kitty --directory <cwd> /bin/sh -c <cmd>` — opens a new top-level kitty instance. We avoid `kitten @ launch --type=os-window` because it requires `allow_remote_control yes` in the user's kitty.conf. A fresh kitty process per `r` keypress is acceptable for v1; users who prefer a new window in the current instance can set `ui.spawn` to a `kitten @ launch` invocation themselves.
- **iTerm2**: `osascript -e <applescript>` where the applescript opens a new window and runs `cd <cwd> && <cmd>` in it
- **Terminal.app**: `osascript -e 'tell application "Terminal" to do script "cd <cwd> && <cmd>"'`
- **.none**: returns `error.NoTerminalDetected`. The caller falls back to printing the command in the footer (existing behavior).

Quoting strategy for the osascript variants: build the AppleScript string in Zig with proper escaping (single quotes around the outer `-e` arg, AppleScript `quoted form of` is not used — we escape inside Zig).

### 4.3 Call site

In `src/infra/inbound/tui/app.zig` `doResume` (current lines 506–514), replace the no-spawn branch:

```zig
// Pseudocode
if (uc.spawn_template == null) {
    const launcher_kind = uc.terminal_launcher.kind;
    if (launcher_kind == .none) {
        // existing footer-print fallback, unchanged
    } else {
        const argv = try terminal_launcher.buildArgv(a, uc.terminal_launcher, spawn_cwd_path, cmd.command);
        defer freeArgv(a, argv);
        _ = try std.process.spawn(uc.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        try state.setMessage(try std.fmt.allocPrint(a, "spawned in {s}", .{@tagName(launcher_kind)}));
    }
} else {
    // existing /bin/sh -c <cmd> detached spawn, unchanged
}
```

`spawn_cwd_path` resolves to `task.project_path orelse std.posix.getenv("HOME") orelse "/"`.

`detect` is called once in `main.zig` at TUI startup and the resulting `Launcher` is stored in `UseCases` alongside `spawn_template`. The TUI never re-detects mid-session.

### 4.4 Config override

If `ui.spawn` (current `spawn_template`) is set in config, the existing wrapped-spawn path is taken and auto-detection is skipped. This is the escape hatch for users on terminals we don't yet detect (e.g. tmux) or who want a custom layout.

## 5. Project picker: fzf-first, inline fallback

### 5.1 Config

Add `project_roots: [][]const u8` to the existing config schema in `src/infra/outbound/config/loader.zig`:

```jsonc
{
  "db_path": "...",
  "repos": [ /* existing */ ],
  "project_roots": [ "~/tru4m", "~/code" ],
  "providers": { /* existing */ },
  "ui": { /* existing */ }
}
```

- Optional field; absent / empty array means "no scanning."
- Paths expand `~/` and `$HOME` at load time.
- Non-existent paths are silently skipped (logged once to stderr, not surfaced in the TUI).

### 5.2 CLI

Mirror the existing `ctt config repo add/list/remove` subcommands:

```
ctt config project-root add <path>
ctt config project-root list
ctt config project-root remove <path>
```

Implemented in `src/infra/inbound/cli/handlers.zig` next to the existing repo handlers.

### 5.3 Candidate list

At TUI startup, build the candidate list once:

1. Start with `cfg.repos` (manually-registered repos).
2. For each `project_root`, `readdir` one level, filter to directories. Skip entries whose name starts with `.` (dotdirs) and skip the fixed denylist `{ "node_modules", "target", ".git", "build", "dist", "zig-cache", "zig-out", ".zig-cache" }`.
3. Each subdir becomes a `Match{ name: basename, path: absolute path }`.
4. Dedupe by absolute path; on collision, the entry from `cfg.repos` wins (so the user's chosen display name takes precedence over `basename`).

The combined list is stored on `tui.State`. Free on TUI shutdown.

### 5.4 fzf availability

At TUI startup, after building the candidate list, check `which fzf`:

```zig
pub fn fzfAvailable(a: std.mem.Allocator) bool {
    var child = std.process.Child.init(&.{ "which", "fzf" }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) { .Exited => |code| code == 0, else => false };
}
```

Result is cached on `State` as `fzf_available: bool`.

### 5.5 fzf launch

New module `src/infra/inbound/tui/fzf_picker.zig`:

```zig
pub const Selection = struct {
    name: []const u8,   // basename
    path: []const u8,   // absolute path
};

/// Suspends the TUI, runs fzf with `candidates` (one "name\tpath" per line)
/// piped to stdin, reads the selected line from fzf's stdout, restores the
/// TUI. Returns null if the user pressed Esc or fzf failed to launch.
pub fn pick(
    a: std.mem.Allocator,
    tui: *Tui,
    candidates: []const Candidate,
) !?Selection;
```

Internals:

1. Tell the TUI to leave the alternate screen and restore canonical line mode (existing tui crate already does this on shutdown — extract into a `suspend()` / `resume()` pair).
2. Spawn `fzf --with-nth=1 --delimiter='\t' --prompt='project> ' --height=40%` with a pipe on stdin.
3. Write `name\tpath\n` lines for each candidate, then close stdin.
4. Read up to one line from fzf's stdout. Wait for exit.
5. Re-enter alternate screen + raw mode, force a full redraw.
6. If exit code is non-zero (user pressed Esc) or output is empty, return `null`.
7. Otherwise parse the line, return the matching `Candidate`.

### 5.6 Trigger

In the Add Todo modal, when the user tabs into (or otherwise focuses) the project field:

- If `fzf_available` is true: immediately call `fzf_picker.pick`. On non-null return, fill the project field. On null, leave the field empty (the user cancelled).
- If `fzf_available` is false: fall through to the existing inline dropdown behavior (lines 203–247 of `app.zig`), but the candidate list is now the merged list from §5.3 rather than just `cfg.repos`.

### 5.7 Free-form path entry

The current modal allows typing a path that doesn't match any candidate. Preserve this: after the fzf picker returns (or is skipped because unavailable), the user can still edit the field as a plain text input. The inline dropdown's "free-form fallback" continues to work in the no-fzf path.

## 6. Module layout

```
src/infra/inbound/tui/
  app.zig                 # call sites change; startup wiring expands
  state.zig               # +candidates, +fzf_available, +terminal_launcher
  modal.zig               # project-field handler unchanged for fzf-unavailable path
  repo_match.zig          # unchanged (still used in fallback)
  terminal_launcher.zig   # NEW — Kind, detect, buildArgv
  fzf_picker.zig          # NEW — suspend/launch/resume
  use_cases.zig           # +terminal_launcher: Launcher
src/infra/outbound/config/
  loader.zig              # +project_roots field, +expand_path helper
src/infra/inbound/cli/
  args.zig                # +ConfigProjectRoot subcommand
  handlers.zig            # +handleConfigProjectRoot{Add,List,Remove}
```

## 7. Tests

- `terminal_launcher.zig` unit tests: each `Kind` from a synthetic `EnvMap`; argv shape for each kind; cwd quoting; `.none` when no relevant env present.
- `loader.zig`: `project_roots` parses; missing field defaults to `&.{}`; `~/` expansion; non-existent paths drop on load.
- `cli/handlers.zig`: `config project-root add/list/remove` round-trip via a tmp config file (mirrors existing `config repo add` tests).
- `tui/state.zig` / startup wiring: candidate list dedupe (repo wins over scanned), denylist applied, scan tolerates non-existent root.
- `fzf_picker.zig`: hard to unit-test (suspend/resume + spawning a real binary). Skip in CI; cover with a manual smoke-test checklist in the PR description.

## 8. Migration & backward compatibility

- `project_roots` is optional with default `&.{}`. Existing configs load unchanged.
- `cfg.repos` keeps working exactly as before.
- `ui.spawn` keeps working exactly as before (overrides auto-detection).
- No DB migration. No schema change in SQLite.

## 9. Post-pick editing

Once fzf returns and the field is filled, the field becomes a normal text input — the user can type to override the path manually. To reopen the fzf picker over the same candidate list, the user presses `Ctrl-P` while focused on the project field. `Ctrl-P` is a no-op when `fzf_available` is false.

fzf availability is determined once at TUI startup and cached for the process. A user installing fzf mid-session won't see it pick up until they restart the TUI; this is fine.

## 10. Out of scope follow-ups

- tmux detection + `tmux new-window` launcher.
- Linux terminal detection.
- `fd`/`rg`-powered deep project discovery as an alternative input to fzf.
- A "Add to configured repos?" prompt after picking a free-form path.
