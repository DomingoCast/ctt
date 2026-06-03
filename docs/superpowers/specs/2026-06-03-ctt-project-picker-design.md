# ctt — Project Picker for Task Creation (Design)

**Date:** 2026-06-03
**Status:** Approved design, not yet implemented
**Builds on:** `2026-06-02-ctt-claude-task-tracker-design.md`, `2026-06-03-ctt-handoff-resume-design.md`, `2026-06-03-ctt-tui-polish-v1-design.md`

## 1. Overview

When creating a task in the TUI, the user should be able to pick which project the task belongs to. The picked project's filesystem path is stored on the task, and on resume (`r` / `R` keys, `ctt resume <id>`), the spawned process inherits that path as its working directory — so when claude (or any other LLM) launches, it opens in the right project.

The picker is a small inline dropdown that fuzzy-matches against the user's configured repos (`cfg.repos`) and offers a free-form path entry as a fallback when no match exists. This lets the feature work both for users who have configured repos via `ctt config repo add` and for first-time users with an empty `cfg.repos` who just want to type a path.

## 2. Goals

- Make `r` open claude in the task's project directory, with zero per-resume prompting.
- One-time choice per task: project is picked once at creation, stored, and reused.
- Discoverable: fuzzy search over configured repos surfaces the right project in a few keystrokes.
- Works with empty `cfg.repos`: free-form path entry lets new users get going without setup.
- Cleanly composes with the existing add-todo modal — no new modes, no full-screen overlays.

## 3. Non-goals (v1)

- No fzf-style subsequence scoring. Substring match is enough.
- No auto-discovery of repos by walking `~/dev`, `~/code`, etc.
- No automatic `cfg.repos` registration after a free-form pick. (Could be a follow-up: "Add to configured repos? [y/N]".)
- No per-resume reprompt to change the project on the fly.
- No card-level display of the project (would clutter the card; detail panel covers it).
- No `{{cwd}}` placeholder in `ui.spawn` templates. We control cwd via the spawn API directly.
- No mouse support for the dropdown.

## 4. Data model & storage

### 4.1 Domain

`src/domain/entities/task.zig`:

```zig
pub const Task = struct {
    // ... existing fields ...
    project_path: ?[]const u8 = null,   // absolute filesystem path; null = legacy / not set
};

pub const NewTask = struct {
    // ... existing fields ...
    project_path: ?[]const u8 = null,
};

pub const TaskPatch = struct {
    // ... existing fields ...
    project_path: ??[]const u8 = null,  // ??: outer null = no change, Some(null) = clear, Some(x) = set
};
```

The string is allocator-owned by the `Task` consumer (mirror existing `notes`, `title` ownership patterns).

### 4.2 SQLite schema — v3 migration

`src/infra/outbound/sqlite/migrations.zig` adds:

```zig
pub const v3: [*:0]const u8 =
    \\BEGIN;
    \\ALTER TABLE tasks ADD COLUMN project_path TEXT;
    \\PRAGMA user_version = 3;
    \\COMMIT;
;
```

`db.zig` applies it when `version < 3`. Idempotent across re-opens because `user_version` gates the `ALTER TABLE` (which itself is not idempotent).

### 4.3 Adapter changes

`SqliteTaskRepository`:
- `TASK_SELECT` gains `t.project_path` as the last column (after the existing `session_provider`/`session_id` at indices 34/35 — new index 36).
- `rowToTask` reads via `nullableText(36)`, dupes into the caller allocator when present, frees on `freeTask` in both copies (application/use_cases/get_context.zig and infra/outbound/sqlite/task_repository.zig — keep both in sync).
- `updateFn` handles `patch.project_path` with the same `Some(handle)/Some(null)/None` shape as existing patch branches.

### 4.4 Application

`AddTodo.execute(a, NewTask)` already takes a `NewTask`; the new `project_path` flows through naturally. No new use case.

## 5. Add-todo modal — Project field + inline picker

### 5.1 Field layout

The existing modal layout grows one row:

```
╭─ ✏ New task ────────────────────────────────╮
│  Title  : auto refresh foo                  │
│  Branch : feat/auto-refresh                 │
│  Issue  :                                   │
│  Project: ctt|                              │
│   ╭───────────────────────────────────────╮ │
│   │ ▶ ctt        /Users/me/tru4m/ctt      │ │
│   │   ctt-data   /Users/me/projects/ctt-…  │ │
│   │   Use path: "ctt"                     │ │
│   ╰───────────────────────────────────────╯ │
│           Tab next · Enter submit · Esc      │
╰─────────────────────────────────────────────╯
```

The dropdown:
- Inset 2 cells from the modal's left edge.
- Rounded border in `state.colors.metadata`.
- Up to 5 matches plus optionally a "Use path: <query>" pseudo-entry.
- Highlighted row uses `.{ .reverse = true }` over `state.colors.title`.

The modal's overall height grows by exactly `2 + N` rows when the dropdown is open, where `N` is the number of visible entries (up to `MAX_RESULTS + 1` for the optional "Use path" pseudo-row). The base modal stays the same shape (~10 rows for 3 fields + new Project field = 11). With dropdown open and 5 matches plus Use-path row, total = 11 + 2 + 6 = 19 rows max. When the dropdown is closed (no Project focus, or after acceptance), modal height returns to base. Centering recomputes per render so the modal stays vertically centered as it grows.

### 5.2 Focus order

Tab cycle: `Title → Branch → Issue → Project → Title → …`

`AddTodoModal` already has `ModalFocus = enum { title, branch, issue }`; extend to `enum { title, branch, issue, project }` and add `project_buf: std.ArrayList(u8)`.

A new field `project_selection: u8 = 0` tracks which dropdown row is highlighted. Resets to 0 whenever the project query changes.

### 5.3 Key handling (when focus is on Project)

| Key | Action |
|---|---|
| Printable char | Append to `project_buf`; recompute matches; reset `project_selection` to 0 |
| Backspace | Pop one char from `project_buf`; same recompute/reset |
| `↑` | Decrement `project_selection`, clamped to 0 |
| `↓` | Increment `project_selection`, clamped to last visible row |
| `Enter` | If dropdown has entries, accept highlight: copy that row's path into `project_buf` and close dropdown (set internal flag `project_dropdown_open = false`). If dropdown was already closed, submit the modal. |
| `Tab` | If dropdown is open with entries, accept highlight as above, then advance focus to Title. Otherwise just advance focus. |
| `Esc` | Cancel modal entirely (existing behavior). |

The "Use path: <query>" row resolves `~`/relative paths via `std.fs.realpathAlloc` or the Zig 0.16 equivalent on Enter/Tab acceptance. If realpath fails (path doesn't exist), the field is still populated with the user-typed string — validation happens on modal submit (§5.4).

### 5.4 Submit validation

On `Tab next · Enter submit` from any non-Project focus:
- If `project_buf` is empty → task is created with `project_path = null`. No validation error.
- If `project_buf` is non-empty → call `std.fs.cwd().statFile` (or equivalent) on the string. If the file is not a directory, the modal stays open; the footer message is set to `"path not found: <path>"` via the existing `state.setMessage` mechanism (persists until the next action or refresh); the Project field's value cells get `.reverse = true` error styling. User can edit and resubmit.

## 6. Fuzzy match logic

### 6.1 Pure helper

`src/infra/inbound/tui/repo_match.zig`:

```zig
pub const Match = struct {
    name: []const u8,
    path: []const u8,
};

pub const MAX_RESULTS: usize = 5;

/// Case-insensitive substring match over `cfg.repos`.
/// Ranks: name-prefix > name-substring > path-substring. Stable within bucket.
/// Returns at most `MAX_RESULTS` entries, filling `out` (which must have capacity ≥ 5).
pub fn fuzzyMatch(
    repos: []const cfg.RepoConfig,
    query: []const u8,
    out: []Match,
) []Match;
```

### 6.2 Algorithm

1. Empty `query` → return first `MAX_RESULTS` repos in config order.
2. Lower-case `query` and (lazily) lower-case the haystack columns for comparison.
3. For each `repo` in config order, determine its score:
   - `name` starts with `query` → bucket 0 (highest)
   - else `name` contains `query` → bucket 1
   - else `path` contains `query` → bucket 2
   - else: skip
4. Stable-sort matches by bucket ascending. Within a bucket, preserve original config order (the iteration order already does this since the stable sort is on an integer key).
5. Truncate to `MAX_RESULTS`.

### 6.3 "Use path" pseudo-entry

The dropdown rendering layer (not `repo_match.zig`) appends a `Use path: <query>` row when:
- `query.len > 0`, AND
- no displayed match has `name == query` or `path == query` (exact-match check, case-sensitive — typing the literal name should suppress the fallback).

This row sits at the bottom and is selectable like any other entry. Its acceptance path resolves with `realpath` and falls back to the raw string on resolve failure.

### 6.4 Tests

Inline tests in `repo_match.zig`:

- `"empty query returns first 5"` — 7 configured, empty query → 5 entries in config order.
- `"name prefix wins over path substring"` — 2 repos; one named `"ctt"` at path `/a/foo`, one named `"foo"` at path `/a/ctt`. Query `ctt` → name-match `ctt` first.
- `"name substring wins over path substring"` — 2 repos; one named `"my-ctt-tool"`, one named `"foo"` at path `/a/ctt`. Query `ctt` → name-match first.
- `"path-only match"` — 1 repo named `"x"` at `/a/ctt/b`. Query `ctt` → returned.
- `"no match returns empty"` — empty out.
- `"truncates at MAX_RESULTS"` — 10 matches → 5 returned.
- `"stable order within bucket"` — 3 name-substring matches in known config order → returned in that order.

## 7. Resume integration (CWD)

### 7.1 CLI

`src/infra/inbound/cli/handlers.zig` `handleResume`:

After loading context, look up the task's `project_path`. When spawning:

```zig
const cwd_opt: ?[]const u8 = ctx.task.project_path;
var child = std.process.spawn(uc.io, .{
    .argv = &[_][]const u8{ "/bin/sh", "-c", cmd.command },
    .stdin = .inherit,
    .stdout = .inherit,
    .stderr = .inherit,
    .cwd = cwd_opt,
});
```

(If Zig 0.16's spawn options use `.cwd_dir: ?std.Io.Dir` instead of `.cwd: ?[]const u8`, open the dir first via `std.Io.Dir.openDirAbsolute(path)` and pass that. Pick whichever the API supports; the principle is that the child inherits the path as its cwd.)

### 7.2 TUI

`src/infra/inbound/tui/app.zig` `doResume`: same change. The detached spawn already exists; only the `.cwd` field is added.

### 7.3 Fallback when path is gone

If `project_path` is set but the directory was removed between task creation and resume, `std.process.spawn` returns an error. The CLI prints `"resume failed: project path not found: <path>"` and exits non-zero. The TUI flashes the same in the footer and does not spawn.

(No automatic clear of the path or fallback to default cwd. The user should `ctt update <id>` to fix or recreate the task.)

## 8. Detail panel display

`renderDetail` (`src/infra/inbound/tui/view.zig`) gains one line, inserted after the Worktree row (or in Worktree's place if both are present — Worktree wins as the more authoritative live link):

```zig
if (ds.task.project_path) |p| {
    // <folder-glyph> Project  <path>
    const line = std.fmt.bufPrint(&buf, "{s} Project  {s}", .{ state.glyphs.folder, p }) catch return;
    _ = sub.printSegment(.{ .text = line, .style = meta_style }, .{ .row_offset = row, .col_offset = 2 });
    row += 1;
}
```

Placement: between Worktree (if any) and PR. If no Worktree, between Session and PR.

No change to card rendering (kanban) — adding another row would push the card from 4 lines to 5, which compounds across columns. Acceptable v1 trade-off; revisit if user demand surfaces.

## 9. Config additions

None. `cfg.RepoConfig` already has `name` and `path` — that's all the picker needs.

## 10. Error handling summary

| Condition | Behaviour |
|---|---|
| User types path that doesn't exist, hits submit | Modal stays open, footer flashes error, project field highlights. |
| User picks a configured repo whose path was deleted from disk | Path is stored regardless; resume fails with clear footer message. |
| `realpath` fails on free-form path | Fall back to the raw user-typed string. Submit validation still rejects it if `statFile` fails. |
| Resume spawn fails because `project_path` directory is gone | Print `"resume failed: project path not found: <path>"`. CLI exits non-zero, TUI footer shows the message. |
| Migration applies on existing DB | All existing tasks get `project_path = NULL`; legacy behavior preserved on resume. |

## 11. Testing strategy

- **Domain:** no new tests; existing literal construction sites pick up `.project_path = null` via default.
- **SQLite:** new test in `db.zig` asserts the `project_path` column exists after migration; existing `task session handle round-trip` test extended to also round-trip a `project_path`.
- **Application:** new test in `add_todo` (if it has inline tests; otherwise via the fake repo) round-trips a non-null `project_path` through `AddTodo.execute`.
- **Pure helper:** `repo_match.zig` gets 7 inline tests (§6.4).
- **Smoke:** extend `tests/smoke.sh` with `ctt add "p" --project /tmp` (if a `--project` CLI flag is also added — see §12), then `ctt context $ID --json | jq -r '.task.project_path'` asserts the value. If the CLI flag is deferred, the smoke just exercises a task with `project_path = null` and confirms resume still works.
- **TUI:** state-machine tests for the new picker key-handling are NOT added (consistent with prior phases' acknowledged gap; manual smoke at G covers it).

## 12. CLI flag (deferred)

A `ctt add "title" --project <path>` flag would let the CLI exercise the field for parity with the TUI. Adding it is mechanical (modify `parseAdd` + `AddArgs`) but not required for the TUI feature. The plan should include it as an optional task or call it explicitly out-of-scope.

**Decision:** include the `--project` flag in the plan. It's a 10-line change and keeps CLI/TUI capability parity.

## 13. Migration

- One schema version bump: 2 → 3. Idempotent. Pre-v3 databases auto-upgrade on first `Db.open`.
- New domain field has `= null` default, so existing literal construction sites (tests, fakes) compile unchanged.
- Existing tasks have `project_path = NULL`; their resume behavior is unchanged (spawn inherits ctt's cwd).

## 14. Out of scope (parked for follow-ups)

- Auto-discovery of repos under `~/dev` etc.
- Prompt-on-pick to add a free-form path to `cfg.repos`.
- `{{cwd}}` placeholder in `ui.spawn` templates for explicit user control.
- Card-level display of `project_path`.
- Per-resume reprompt to change the project on the fly.
- fzf-style subsequence scoring + multi-character ranking.
- Mouse support on the dropdown.

## 15. Acknowledged unknowns

1. **Zig 0.16 `std.process.spawn` cwd field name.** Could be `.cwd: ?[]const u8`, `.cwd_dir: ?std.Io.Dir`, or split across `.cwd_path` / `.cwd_dir`. Implementation inspects and uses the available shape.
2. **`std.fs.realpathAlloc` availability.** If renamed in 0.16 (`std.Io.Dir.realpath`?), use whatever the existing config loader / git infra uses to resolve paths.
3. **TUI modal centering with variable height.** When dropdown opens, modal grows. Centering should recompute every render so the modal stays vertically centered as it grows. Implementation must not cache the y-offset across frames.
