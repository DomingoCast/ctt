# ctt Project Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Task.project_path: ?[]const u8` and an inline fuzzy-match picker for it in the add-todo modal, so `r` (resume) launches claude with the spawned process's cwd set to the task's project directory.

**Architecture:** New domain field with SQLite v3 migration. Pure `repo_match.zig` helper provides fuzzy matching against `cfg.repos`. Add-todo modal grows a Project field with an inline dropdown that closes the modal's existing focus cycle (Title→Branch→Issue→Project). Resume in CLI + TUI passes `cwd = task.project_path` to `std.process.spawn`. CLI gets a `--project` flag for parity.

**Tech Stack:** Zig 0.16, zqlite, libvaxis 0.6.

**Spec:** `docs/superpowers/specs/2026-06-03-ctt-project-picker-design.md` (commit `5cdd03d`).

---

## File map

**Create:**
- `src/infra/inbound/tui/repo_match.zig` — pure fuzzy-match helper

**Modify (domain & schema):**
- `src/domain/entities/task.zig` — `Task.project_path`, `NewTask.project_path`, `TaskPatch.project_path`
- `src/infra/outbound/sqlite/migrations.zig` — `v3` constant
- `src/infra/outbound/sqlite/db.zig` — apply v3 + tests
- `src/infra/outbound/sqlite/task_repository.zig` — read/write `project_path` column
- `src/application/use_cases/get_context.zig` — extend `freeTask` for `project_path`
- `src/application/tests/fake_task_repo.zig` — extend update path

**Modify (CLI):**
- `src/infra/inbound/cli/args.zig` — `AddArgs.project`, `parseAdd` accepts `--project`, `freeCommand` arm
- `src/infra/inbound/cli/handlers.zig` — `handleAdd` passes project; `handleResume` spawns with cwd

**Modify (TUI):**
- `src/infra/inbound/tui/state.zig` — `ModalFocus` adds `.project`, `AddTodoModal` adds `project_buf` + dropdown state
- `src/infra/inbound/tui/modal.zig` — render Project field + dropdown
- `src/infra/inbound/tui/app.zig` — modal key dispatch for Project focus; `doResume` spawns with cwd
- `src/infra/inbound/tui/use_cases.zig` — expose `cfg.repos` via existing path or add a new field
- `src/infra/inbound/tui/view.zig` — detail panel shows Project line
- `src/main.zig` — wire `cfg.repos` to TUI UseCases if not already

---

## Phase A — Domain & schema

### Task A1: `Task.project_path` field

**Files:**
- Modify: `src/domain/entities/task.zig`

- [ ] **Step 1: Add the field to `Task`, `NewTask`, `TaskPatch`**

In `Task` struct, add after `session`:

```zig
project_path: ?[]const u8 = null,
```

Wait — per the Phase A audit pattern from handoff/resume (removing defaults to force compile-time enforcement), this field should NOT have a default on `Task`. Use:

```zig
project_path: ?[]const u8,
```

In `NewTask`:

```zig
project_path: ?[]const u8 = null,
```

In `TaskPatch`:

```zig
project_path: ??[]const u8 = null,  // ??: outer null = no change, Some(null) = clear, Some(x) = set
```

- [ ] **Step 2: Audit and fix all `Task{...}` literal sites**

Run `zig build test` to see compile errors. The Phase A pattern from handoff/resume lists known sites:

- `src/infra/inbound/mcp/server.zig` (MiniRepo.createFn test fake)
- `src/infra/inbound/cli/handlers.zig` (MiniRepo + renderJson test literal)
- `src/infra/outbound/sqlite/task_repository.zig` (DB row constructor)
- `src/application/tests/fake_task_repo.zig` (FakeTaskRepo.createFn)
- `src/domain/services/status_derive.zig` (baseTask helper)

Add `.project_path = null` to each. For `task_repository.zig:rowToTask`, leave as `null` for now — Task B1 wires the real column read.

- [ ] **Step 3: Run tests**

```
zig build test
```

Expected: 178 (or whatever current count) tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/domain/entities/task.zig src/infra/inbound/mcp/server.zig src/infra/inbound/cli/handlers.zig src/infra/outbound/sqlite/task_repository.zig src/application/tests/fake_task_repo.zig src/domain/services/status_derive.zig
git commit -m "feat(domain): Task gains optional project_path"
```

---

### Task A2: SQLite v3 migration

**Files:**
- Modify: `src/infra/outbound/sqlite/migrations.zig`
- Modify: `src/infra/outbound/sqlite/db.zig`

- [ ] **Step 1: Add `v3` constant**

Append to `migrations.zig`:

```zig
pub const v3: [*:0]const u8 =
    \\BEGIN;
    \\ALTER TABLE tasks ADD COLUMN project_path TEXT;
    \\PRAGMA user_version = 3;
    \\COMMIT;
;
```

- [ ] **Step 2: Apply v3 in `db.zig`**

In `Db.migrate()`, after the `version < 2` block, add:

```zig
if (version < 3) {
    try self.conn.execNoArgs(migrations.v3);
}
```

- [ ] **Step 3: Add migration test**

In `db.zig` (alongside the existing v2 test):

```zig
test "v3 migration adds project_path column" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "v3.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();

    var ver_row = (try db.conn.row("PRAGMA user_version", .{})).?;
    defer ver_row.deinit();
    try std.testing.expectEqual(@as(i64, 3), ver_row.int(0));

    var col_rows = try db.conn.rows("PRAGMA table_info(tasks)", .{});
    defer col_rows.deinit();
    var found = false;
    while (col_rows.next()) |r| {
        if (std.mem.eql(u8, r.text(1), "project_path")) found = true;
    }
    try std.testing.expect(found);
}
```

- [ ] **Step 4: Run tests**

```
zig build test
```

Expected: new test passes; existing v1/v2 tests still pass; idempotency test still passes (re-opening a v3 DB doesn't re-run migrations).

- [ ] **Step 5: Commit**

```bash
git add src/infra/outbound/sqlite/migrations.zig src/infra/outbound/sqlite/db.zig
git commit -m "feat(infra/sqlite): v3 migration — project_path column"
```

---

### Task A3: `SqliteTaskRepository` reads/writes `project_path`

**Files:**
- Modify: `src/infra/outbound/sqlite/task_repository.zig`

The current `TASK_SELECT` ends at column index 35 (`t.session_id`). New column `t.project_path` becomes index 36.

- [ ] **Step 1: Failing test — round-trip a `project_path`**

Add to the tests block of `task_repository.zig`:

```zig
test "task project_path round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try @import("db.zig").tmpDbPath(std.testing.allocator, tmp, "proj.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try @import("db.zig").Db.open(path_z);
    defer db.close();

    var repo = SqliteTaskRepository.init(&db);
    const iface = repo.interface();

    const created = try iface.create(std.testing.allocator, .{
        .title = "t",
        .project_path = "/tmp/some-project",
    });
    const id = created.id;
    // Free created
    std.testing.allocator.free(created.title);
    if (created.project_path) |p| std.testing.allocator.free(p);

    const got = (try iface.get(std.testing.allocator, id)).?;
    defer std.testing.allocator.free(got.title);
    defer if (got.project_path) |p| std.testing.allocator.free(p);

    if (got.project_path) |p| {
        try std.testing.expectEqualStrings("/tmp/some-project", p);
    } else try std.testing.expect(false);
}

test "task project_path patch clear" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try @import("db.zig").tmpDbPath(std.testing.allocator, tmp, "proj2.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try @import("db.zig").Db.open(path_z);
    defer db.close();

    var repo = SqliteTaskRepository.init(&db);
    const iface = repo.interface();

    const t = try iface.create(std.testing.allocator, .{ .title = "t", .project_path = "/tmp/p" });
    const id = t.id;
    std.testing.allocator.free(t.title);
    if (t.project_path) |p| std.testing.allocator.free(p);

    _ = try iface.update(std.testing.allocator, id, .{ .project_path = @as(?[]const u8, null) });

    const got = (try iface.get(std.testing.allocator, id)).?;
    defer std.testing.allocator.free(got.title);
    try std.testing.expect(got.project_path == null);
}
```

- [ ] **Step 2: Run — confirm tests fail**

```
zig build test 2>&1 | grep "project_path" | head
```

Expected: compile/test failures — column not in SELECT, patch field not handled, `create` doesn't write the column.

- [ ] **Step 3: Add `project_path` to `TASK_SELECT`**

Append `, t.project_path` as the last column in `TASK_SELECT`. Update the layout comment block at the top of the file:

```
// 36  t.project_path
```

- [ ] **Step 4: Update `rowToTask` to read column 36**

After the existing session-handle read block, add:

```zig
const pp_raw = row.nullableText(36);
const project_path: ?[]const u8 = if (pp_raw) |p| try a.dupe(u8, p) else null;
```

…and add `.project_path = project_path` to the returned `Task` literal (replacing the `.project_path = null` placeholder from Task A1).

Add `errdefer if (project_path) |p| a.free(p);` immediately before the Task struct construction (mirror existing errdefer pattern for `session`).

- [ ] **Step 5: Update `createFn` to write `project_path` on insert**

Locate the existing INSERT:

```zig
conn.exec(
    "INSERT INTO tasks (title, branch_hint, notes) VALUES (?, ?, ?)",
    .{ draft.title, branch_hint_text, draft.notes },
)
```

Extend to:

```zig
conn.exec(
    "INSERT INTO tasks (title, branch_hint, notes, project_path) VALUES (?, ?, ?, ?)",
    .{ draft.title, branch_hint_text, draft.notes, draft.project_path },
)
```

- [ ] **Step 6: Handle `TaskPatch.project_path` in `updateFn`**

In the patch chain (where `session`, `worktree_id`, etc. are handled), add at the end:

```zig
if (patch.project_path) |maybe_pp| {
    if (maybe_pp) |pp| {
        conn.exec(
            "UPDATE tasks SET project_path = ?, updated_at = datetime('now') WHERE id = ?",
            .{ pp, id.raw() },
        ) catch |e| return mapErr(e);
    } else {
        conn.exec(
            "UPDATE tasks SET project_path = NULL, updated_at = datetime('now') WHERE id = ?",
            .{id.raw()},
        ) catch |e| return mapErr(e);
    }
}
```

- [ ] **Step 7: Extend `freeTask` helper to free `project_path`**

Locate `freeTask` near the bottom of the file. Add:

```zig
if (t.project_path) |p| a.free(p);
```

(After the existing session free.)

- [ ] **Step 8: Run tests**

```
zig build test
```

Expected: both new tests pass; existing tests still pass.

- [ ] **Step 9: Commit**

```bash
git add src/infra/outbound/sqlite/task_repository.zig
git commit -m "feat(infra/sqlite): persist project_path on tasks"
```

---

### Task A4: Application `freeTask` mirror

**Files:**
- Modify: `src/application/use_cases/get_context.zig`
- Modify: `src/application/tests/fake_task_repo.zig`

- [ ] **Step 1: Mirror the new free in `get_context.zig`**

Locate the `freeTask` function there (the byte-identical sibling of the sqlite copy). Add the same `if (t.project_path) |p| a.free(p);` line in the same position.

- [ ] **Step 2: Extend `FakeTaskRepo.updateFn`**

In `fake_task_repo.zig`, locate the patch handler. After the existing branches for `session`, `worktree_id`, etc., add:

```zig
if (patch.project_path) |maybe_pp| {
    existing.project_path = maybe_pp;
}
```

If `existing.project_path` was previously a heap copy from `create`, also free the old value before reassigning. Match the existing pattern for other heap fields in this fake (e.g. `title`).

- [ ] **Step 3: Build + test**

```
zig build test
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add src/application/use_cases/get_context.zig src/application/tests/fake_task_repo.zig
git commit -m "feat(app): freeTask + FakeTaskRepo handle project_path"
```

---

## Phase B — Pure fuzzy match helper

### Task B1: `repo_match.zig`

**Files:**
- Create: `src/infra/inbound/tui/repo_match.zig`
- Modify: `src/infra/inbound/tui/root.zig` (register tests)

- [ ] **Step 1: Write the module + tests**

Create `src/infra/inbound/tui/repo_match.zig`:

```zig
const std = @import("std");
const cfg = @import("infra_config");

pub const Match = struct {
    name: []const u8,
    path: []const u8,
};

pub const MAX_RESULTS: usize = 5;

/// Case-insensitive substring fuzzy match.
/// Ranks: name-prefix (bucket 0) > name-substring (bucket 1) > path-substring (bucket 2).
/// Within a bucket, preserves original config order (stable).
/// Empty query returns the first MAX_RESULTS repos in config order.
/// Returns at most MAX_RESULTS entries from `out` (caller-supplied with capacity ≥ MAX_RESULTS).
pub fn fuzzyMatch(repos: []const cfg.RepoConfig, query: []const u8, out: []Match) []Match {
    std.debug.assert(out.len >= MAX_RESULTS);

    if (query.len == 0) {
        const n = @min(repos.len, MAX_RESULTS);
        for (repos[0..n], 0..) |r, i| {
            out[i] = .{ .name = r.name, .path = r.path };
        }
        return out[0..n];
    }

    var lower_q_buf: [256]u8 = undefined;
    if (query.len > lower_q_buf.len) return out[0..0];
    const lq = std.ascii.lowerString(&lower_q_buf, query);

    // Score each repo: 0 (best), 1, 2 — or 255 (skip).
    var scored: [256]struct { bucket: u8, idx: usize } = undefined;
    var n: usize = 0;

    for (repos, 0..) |r, i| {
        if (n >= scored.len) break;
        const score = scoreRepo(r, lq);
        if (score < 255) {
            scored[n] = .{ .bucket = score, .idx = i };
            n += 1;
        }
    }

    // Stable sort by bucket asc.
    std.mem.sort(@TypeOf(scored[0]), scored[0..n], {}, struct {
        fn lt(_: void, a: anytype, b: anytype) bool {
            if (a.bucket != b.bucket) return a.bucket < b.bucket;
            return a.idx < b.idx; // stable by original config order
        }
    }.lt);

    const take = @min(n, MAX_RESULTS);
    for (scored[0..take], 0..) |s, i| {
        out[i] = .{ .name = repos[s.idx].name, .path = repos[s.idx].path };
    }
    return out[0..take];
}

fn scoreRepo(r: cfg.RepoConfig, lq: []const u8) u8 {
    var name_buf: [256]u8 = undefined;
    var path_buf: [1024]u8 = undefined;
    if (r.name.len > name_buf.len or r.path.len > path_buf.len) return 255;
    const ln = std.ascii.lowerString(&name_buf, r.name);
    const lp = std.ascii.lowerString(&path_buf, r.path);

    if (std.mem.startsWith(u8, ln, lq)) return 0;
    if (std.mem.indexOf(u8, ln, lq) != null) return 1;
    if (std.mem.indexOf(u8, lp, lq) != null) return 2;
    return 255;
}

// ─── Tests ────────────────────────────────────────────────────────────────

fn r(name: []const u8, path: []const u8) cfg.RepoConfig {
    return .{ .name = name, .path = path };
}

test "empty query returns first 5" {
    const repos = [_]cfg.RepoConfig{
        r("a", "/a"), r("b", "/b"), r("c", "/c"),
        r("d", "/d"), r("e", "/e"), r("f", "/f"),
        r("g", "/g"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "", &out);
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqualStrings("a", got[0].name);
    try std.testing.expectEqualStrings("e", got[4].name);
}

test "name prefix wins over path substring" {
    const repos = [_]cfg.RepoConfig{
        r("foo", "/path/with/ctt/in/it"),
        r("ctt", "/elsewhere"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("ctt", got[0].name);
    try std.testing.expectEqualStrings("foo", got[1].name);
}

test "name substring wins over path substring" {
    const repos = [_]cfg.RepoConfig{
        r("foo", "/path/with/ctt"),
        r("my-ctt-tool", "/elsewhere"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("my-ctt-tool", got[0].name);
    try std.testing.expectEqualStrings("foo", got[1].name);
}

test "path-only match" {
    const repos = [_]cfg.RepoConfig{
        r("x", "/a/ctt/b"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("x", got[0].name);
}

test "no match returns empty" {
    const repos = [_]cfg.RepoConfig{ r("a", "/a"), r("b", "/b") };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "zzz", &out);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "truncates at MAX_RESULTS" {
    const repos = [_]cfg.RepoConfig{
        r("ctt-1", "/"), r("ctt-2", "/"), r("ctt-3", "/"),
        r("ctt-4", "/"), r("ctt-5", "/"), r("ctt-6", "/"),
        r("ctt-7", "/"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqualStrings("ctt-1", got[0].name);
    try std.testing.expectEqualStrings("ctt-5", got[4].name);
}

test "case insensitive match" {
    const repos = [_]cfg.RepoConfig{
        r("CTT", "/users/me/CTT"),
    };
    var out: [MAX_RESULTS]Match = undefined;
    const got = fuzzyMatch(&repos, "ctt", &out);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("CTT", got[0].name);
}
```

(`cfg.RepoConfig` must be reachable as `cfg.RepoConfig`. Phase A1 of TUI polish already wired `infra_config` into `infra_tui`. If `RepoConfig` isn't re-exported from `infra_config/root.zig`, add `pub const RepoConfig = loader.RepoConfig;` there in the same commit.)

- [ ] **Step 2: Register test import in `tui/root.zig`**

Add `_ = @import("repo_match.zig");` to the test block in `src/infra/inbound/tui/root.zig`.

- [ ] **Step 3: Run tests**

```
zig build test
```

Expected: 7 new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/infra/inbound/tui/repo_match.zig src/infra/inbound/tui/root.zig src/infra/outbound/config/root.zig
git commit -m "feat(infra/tui): repo_match.zig — fuzzy match for project picker"
```

---

## Phase C — CLI

### Task C1: `--project` flag on `ctt add`

**Files:**
- Modify: `src/infra/inbound/cli/args.zig`
- Modify: `src/infra/inbound/cli/handlers.zig`

- [ ] **Step 1: Extend `AddArgs`**

In `args.zig`, find `pub const AddArgs = struct { ... }` and add:

```zig
project: ?[]const u8 = null,
```

- [ ] **Step 2: Update `parseAdd`**

In the `while` loop of `parseAdd`, after the existing `--issue` branch, add:

```zig
} else if (std.mem.eql(u8, arg, "--project")) {
    i += 1;
    if (i >= argv.len) return error.MissingArg;
    result.project = try a.dupe(u8, argv[i]);
```

Also add an errdefer near the top of the function:

```zig
errdefer if (result.project) |p| a.free(p);
```

- [ ] **Step 3: Update `freeCommand`**

In the `.add => |v|` arm of `freeCommand`, add at the end:

```zig
if (v.project) |p| a.free(p);
```

- [ ] **Step 4: Update `handleAdd` to pass project**

In `handlers.zig` `handleAdd`, update the `add_todo.execute` call:

```zig
const t = try uc.add_todo.execute(a, .{
    .title = args.title,
    .branch_hint = branch_name,
    .project_path = args.project,
});
```

- [ ] **Step 5: Add a parser test**

Add to args.zig tests:

```zig
test "parse 'add foo --project /tmp/p'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "add")),
        @constCast(@as([:0]const u8, "foo")),
        @constCast(@as([:0]const u8, "--project")),
        @constCast(@as([:0]const u8, "/tmp/p")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqualStrings("foo", cmd.add.title);
    try std.testing.expectEqualStrings("/tmp/p", cmd.add.project.?);
}
```

- [ ] **Step 6: Run tests**

```
zig build test
```

Expected: new test passes.

- [ ] **Step 7: Commit**

```bash
git add src/infra/inbound/cli/args.zig src/infra/inbound/cli/handlers.zig
git commit -m "feat(infra/cli): ctt add --project flag"
```

---

### Task C2: `handleResume` spawns with cwd

**Files:**
- Modify: `src/infra/inbound/cli/handlers.zig`

- [ ] **Step 1: Update the spawn call**

Locate `handleResume`'s `std.process.spawn(uc.io, .{...})` call (the path that actually launches /bin/sh -c). Add a `.cwd` field:

```zig
var child = std.process.spawn(uc.io, .{
    .argv = &[_][]const u8{ "/bin/sh", "-c", cmd.command },
    .stdin = .inherit,
    .stdout = .inherit,
    .stderr = .inherit,
    .cwd = ctx.task.project_path,
});
```

If Zig 0.16's spawn options struct uses a different field name (`.cwd_path` or `.cwd_dir` taking a `std.Io.Dir`), use that instead. Inspect `zig-pkg/...` or the existing process-spawn calls elsewhere to confirm. The principle: pass the optional path so the spawned process starts in that directory.

If `.cwd` is unavailable and only `.cwd_dir` exists, derive the dir:

```zig
const cwd_dir: ?std.Io.Dir = if (ctx.task.project_path) |p|
    std.Io.Dir.openDirAbsolute(uc.io, p, .{}) catch null
else
    null;
defer if (cwd_dir) |d| d.close();
// pass .cwd_dir = cwd_dir
```

- [ ] **Step 2: Build**

```
zig build
```

Expected: success.

- [ ] **Step 3: Manual smoke (optional)**

```bash
./zig-out/bin/ctt add "smoke proj" --project /tmp
ID=$(./zig-out/bin/ctt list --json | jq '.[-1].task.id')
./zig-out/bin/ctt session set $ID claude smoke-id
./zig-out/bin/ctt resume $ID --print
# Should print the rendered command. We can't observe cwd from --print, but the command should render.
./zig-out/bin/ctt delete $ID
```

- [ ] **Step 4: Commit**

```bash
git add src/infra/inbound/cli/handlers.zig
git commit -m "feat(infra/cli): ctt resume spawns child with task.project_path as cwd"
```

---

## Phase D — TUI: Modal state + key handling

### Task D1: Extend `AddTodoModal` for Project field

**Files:**
- Modify: `src/infra/inbound/tui/state.zig`

- [ ] **Step 1: Extend `ModalFocus` and `AddTodoModal`**

Replace `pub const ModalFocus = enum { title, branch, issue };` with:

```zig
pub const ModalFocus = enum { title, branch, issue, project };
```

Extend `AddTodoModal`:

```zig
pub const AddTodoModal = struct {
    focus: ModalFocus = .title,
    title_buf: std.ArrayList(u8) = .empty,
    branch_buf: std.ArrayList(u8) = .empty,
    issue_buf: std.ArrayList(u8) = .empty,
    project_buf: std.ArrayList(u8) = .empty,
    project_selection: u8 = 0,
    project_dropdown_open: bool = false,
    // ... existing methods ...
```

Update `deinit`:

```zig
pub fn deinit(self: *AddTodoModal, a: std.mem.Allocator) void {
    self.title_buf.deinit(a);
    self.branch_buf.deinit(a);
    self.issue_buf.deinit(a);
    self.project_buf.deinit(a);
}
```

Update `focused()`:

```zig
pub fn focused(self: *AddTodoModal) *std.ArrayList(u8) {
    return switch (self.focus) {
        .title => &self.title_buf,
        .branch => &self.branch_buf,
        .issue => &self.issue_buf,
        .project => &self.project_buf,
    };
}
```

Update `cycleFocus()`:

```zig
pub fn cycleFocus(self: *AddTodoModal) void {
    self.focus = switch (self.focus) {
        .title => .branch,
        .branch => .issue,
        .issue => .project,
        .project => .title,
    };
}
```

- [ ] **Step 2: Run tests**

```
zig build test
```

Expected: existing modal tests still pass.

- [ ] **Step 3: Commit**

```bash
git add src/infra/inbound/tui/state.zig
git commit -m "feat(infra/tui): AddTodoModal gains project field + dropdown state"
```

---

### Task D2: TUI `UseCases` exposes `cfg.repos` for picker

**Files:**
- Modify: `src/infra/inbound/tui/use_cases.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Add field**

Open `src/infra/inbound/tui/use_cases.zig`. The struct probably already has `repos: []const d.Repo` (used by `RefreshAll`). The picker needs `cfg.repos` (the CONFIG-layer struct, not the domain `Repo`). These have different shapes.

Add a separate field:

```zig
cfg_repos: []const cfg.RepoConfig = &.{},
```

- [ ] **Step 2: Wire in main.zig**

In the `.none` branch of `main()`, find the `tui.UseCases{...}` literal. Add:

```zig
.cfg_repos = cfg.repos,
```

- [ ] **Step 3: Build + tests**

```
zig build test
```

- [ ] **Step 4: Commit**

```bash
git add src/infra/inbound/tui/use_cases.zig src/main.zig
git commit -m "feat(infra/tui): expose cfg.repos to TUI for project picker"
```

---

### Task D3: Modal key handling for Project focus

**Files:**
- Modify: `src/infra/inbound/tui/app.zig`

- [ ] **Step 1: Update `handleModalKey`**

Locate `handleModalKey` in `app.zig`. It currently handles printable chars, backspace, Tab, Enter, Esc for the focused field.

Wrap the existing logic with a special path when `modal.focus == .project`:

```zig
fn handleModalKey(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, k: vaxis.Key) !void {
    const modal = &state.add_todo_modal;

    if (k.matches(vaxis.Key.escape, .{})) {
        modal.reset(a);
        state.mode = .normal;
        return;
    }

    if (modal.focus == .project) {
        return handleProjectFieldKey(a, uc, state, k);
    }

    // ... existing non-project handling ...
}
```

Then add `handleProjectFieldKey`:

```zig
fn handleProjectFieldKey(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, k: vaxis.Key) !void {
    const modal = &state.add_todo_modal;

    // Compute current matches for dropdown navigation
    var match_buf: [repo_match.MAX_RESULTS]repo_match.Match = undefined;
    const matches = repo_match.fuzzyMatch(uc.cfg_repos, modal.project_buf.items, &match_buf);
    const has_use_path = modal.project_buf.items.len > 0 and !exactMatch(matches, modal.project_buf.items);
    const visible_rows: u8 = @intCast(matches.len + @as(usize, if (has_use_path) 1 else 0));

    if (k.matches(vaxis.Key.up, .{})) {
        if (modal.project_selection > 0) modal.project_selection -= 1;
        modal.project_dropdown_open = true;
        return;
    }
    if (k.matches(vaxis.Key.down, .{})) {
        if (modal.project_selection + 1 < visible_rows) modal.project_selection += 1;
        modal.project_dropdown_open = true;
        return;
    }
    if (k.matches(vaxis.Key.tab, .{})) {
        if (modal.project_dropdown_open and visible_rows > 0) {
            try acceptProjectSelection(a, modal, matches, has_use_path);
        }
        modal.project_dropdown_open = false;
        modal.cycleFocus();
        return;
    }
    if (k.matches(vaxis.Key.enter, .{})) {
        if (modal.project_dropdown_open and visible_rows > 0) {
            try acceptProjectSelection(a, modal, matches, has_use_path);
            modal.project_dropdown_open = false;
            return;
        }
        // Dropdown closed: submit modal
        try submitAddTodo(a, uc, state);
        return;
    }
    if (k.matches(vaxis.Key.backspace, .{})) {
        if (modal.project_buf.items.len > 0) _ = modal.project_buf.pop();
        modal.project_selection = 0;
        modal.project_dropdown_open = true;
        return;
    }
    if (k.text) |t| {
        try modal.project_buf.appendSlice(a, t);
        modal.project_selection = 0;
        modal.project_dropdown_open = true;
        return;
    }
}

fn exactMatch(matches: []const repo_match.Match, query: []const u8) bool {
    for (matches) |m| {
        if (std.mem.eql(u8, m.name, query) or std.mem.eql(u8, m.path, query)) return true;
    }
    return false;
}

fn acceptProjectSelection(
    a: std.mem.Allocator,
    modal: *state_mod.AddTodoModal,
    matches: []const repo_match.Match,
    has_use_path: bool,
) !void {
    const sel = modal.project_selection;
    if (sel < matches.len) {
        // Configured repo selected — copy its path into project_buf
        modal.project_buf.clearRetainingCapacity();
        try modal.project_buf.appendSlice(a, matches[sel].path);
    } else if (has_use_path) {
        // "Use path: <query>" selected — try realpath
        const raw = modal.project_buf.items;
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const resolved = std.fs.realpath(raw, &path_buf) catch raw;
        if (!std.mem.eql(u8, resolved, raw)) {
            modal.project_buf.clearRetainingCapacity();
            try modal.project_buf.appendSlice(a, resolved);
        }
        // Else: leave the buffer as-is.
    }
    modal.project_selection = 0;
}
```

And factor the existing submit logic into `submitAddTodo` (it was previously inlined in the Enter branch). Locate the existing `if (k.matches(vaxis.Key.enter, .{}))` branch's body in `handleModalKey` and move it into:

```zig
fn submitAddTodo(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State) !void {
    const modal = &state.add_todo_modal;
    const title = modal.title_buf.items;
    if (title.len == 0) return;

    // Validate project_path if non-empty
    const project_raw = modal.project_buf.items;
    if (project_raw.len > 0) {
        std.fs.cwd().statFile(project_raw) catch {
            const msg = try std.fmt.allocPrint(a, "path not found: {s}", .{project_raw});
            defer a.free(msg);
            try state.setMessage(msg);
            return;
        };
    }
    const project_path: ?[]const u8 = if (project_raw.len > 0) project_raw else null;

    const branch_name = if (modal.branch_buf.items.len > 0)
        d.BranchName.init(modal.branch_buf.items)
    else
        null;

    _ = uc.add_todo.execute(a, .{
        .title = title,
        .branch_hint = branch_name,
        .project_path = project_path,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(a, "add failed: {s}", .{@errorName(err)});
        defer a.free(msg);
        try state.setMessage(msg);
        return;
    };

    modal.reset(a);
    state.mode = .normal;
    try doRefresh(a, uc, state, true);
}
```

Update the existing modal Enter-branch to call `submitAddTodo`.

Add imports near top of `app.zig` if not already there:

```zig
const repo_match = @import("repo_match.zig");
```

- [ ] **Step 2: Build**

```
zig build
```

Expected: success.

- [ ] **Step 3: Commit**

```bash
git add src/infra/inbound/tui/app.zig
git commit -m "feat(infra/tui): project field key handling + fuzzy dropdown nav"
```

---

### Task D4: Modal render — Project field + dropdown

**Files:**
- Modify: `src/infra/inbound/tui/modal.zig`

- [ ] **Step 1: Render the Project field row**

In `renderAddTodo`, after the existing `Issue` field render, add:

```zig
renderField(sub, "Project", modal.project_buf.items, modal.focus == .project, 8);
```

(Row 8 in the existing modal layout; adjust if the modal is more compact.)

- [ ] **Step 2: Render dropdown when project focus + dropdown open**

After the field renders, if the project field is focused and the dropdown is open, render the inline dropdown sub-window. Add:

```zig
if (modal.focus == .project and modal.project_dropdown_open) {
    var match_buf: [repo_match.MAX_RESULTS]repo_match.Match = undefined;
    const matches = repo_match.fuzzyMatch(state.cfg_repos, modal.project_buf.items, &match_buf);
    const has_use_path = modal.project_buf.items.len > 0 and !exactMatchInline(matches, modal.project_buf.items);
    const dropdown_rows: u16 = @intCast(matches.len + @as(usize, if (has_use_path) 1 else 0));
    if (dropdown_rows > 0) {
        const dd_w: u16 = sub.width -| 4;
        const dd_h: u16 = dropdown_rows + 2;
        const dd = sub.child(.{
            .x_off = 2,
            .y_off = 9,  // immediately below the Project field
            .width = dd_w,
            .height = dd_h,
            .border = .{
                .where = .all,
                .glyphs = .single_rounded,
                .style = .{ .fg = state.colors.metadata.toVaxis() },
            },
        });
        var row: u16 = 0;
        for (matches, 0..) |m, i| {
            const selected = i == modal.project_selection;
            const style: vaxis.Cell.Style = if (selected) .{ .reverse = true, .fg = state.colors.title.toVaxis() } else .{ .fg = state.colors.title.toVaxis() };
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "{s}  {s}", .{ m.name, m.path }) catch continue;
            _ = dd.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row, .col_offset = 2 });
            row += 1;
        }
        if (has_use_path) {
            const selected = modal.project_selection == matches.len;
            const style: vaxis.Cell.Style = if (selected) .{ .reverse = true, .fg = state.colors.title.toVaxis() } else .{ .fg = state.colors.metadata.toVaxis() };
            var line_buf: [256]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "Use path: \"{s}\"", .{modal.project_buf.items}) catch return;
            _ = dd.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row, .col_offset = 2 });
        }
    }
}
```

(`renderAddTodo` will need to accept the cfg.repos via state. State doesn't currently hold them — they're in UseCases. Easiest fix: pass UseCases (or just cfg_repos) into `renderAddTodo`. Alternatively, stash cfg_repos on State at run-init.)

Update the call site in `app.zig` if signature changes. Simplest: add a `cfg_repos: []const cfg.RepoConfig` field to State, mirroring how `glyphs` and `colors` are seeded at run-init from UseCases. In `run()`:

```zig
state.cfg_repos = uc.cfg_repos;
```

Then `renderAddTodo` signature stays the same `(win, modal, state)` and reads `state.cfg_repos`.

Add `exactMatchInline` private helper near the bottom of `modal.zig`:

```zig
fn exactMatchInline(matches: []const repo_match.Match, query: []const u8) bool {
    for (matches) |m| {
        if (std.mem.eql(u8, m.name, query) or std.mem.eql(u8, m.path, query)) return true;
    }
    return false;
}
```

Add import at top of modal.zig:

```zig
const repo_match = @import("repo_match.zig");
```

Also update `state.zig`:

```zig
pub const State = struct {
    // ... existing fields ...
    cfg_repos: []const @import("infra_config").RepoConfig = &.{},
};
```

- [ ] **Step 2: Build + manual smoke**

```
zig build
./zig-out/bin/ctt
# Press n, Tab to Project, type to filter, arrows to move, Enter to pick
```

- [ ] **Step 3: Commit**

```bash
git add src/infra/inbound/tui/modal.zig src/infra/inbound/tui/app.zig src/infra/inbound/tui/state.zig
git commit -m "feat(infra/tui): render Project field + inline dropdown picker"
```

---

## Phase E — Detail panel + TUI resume CWD

### Task E1: Detail panel shows project line

**Files:**
- Modify: `src/infra/inbound/tui/view.zig`

- [ ] **Step 1: Add the Project line in `renderDetail`**

After the Worktree section (or in Worktree's place if not set), add:

```zig
if (ds.task.project_path) |p| {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s} Project  {s}", .{ state.glyphs.folder, p }) catch return;
    _ = sub.printSegment(.{ .text = line, .style = meta_style }, .{ .row_offset = row, .col_offset = 2 });
    row += 1;
}
```

Position: between Worktree and PR. If you find both Project and Worktree are set, render both (project line first, then worktree).

- [ ] **Step 2: Build + commit**

```bash
zig build
git add src/infra/inbound/tui/view.zig
git commit -m "feat(infra/tui): detail panel shows project_path"
```

---

### Task E2: TUI `doResume` spawns with cwd

**Files:**
- Modify: `src/infra/inbound/tui/app.zig`

- [ ] **Step 1: Update `doResume`'s spawn**

Locate the `std.process.spawn` call in `doResume`. Add `.cwd = ctx.task.project_path` (or the Zig 0.16 equivalent — see C2 step 1 for the fallback to `.cwd_dir`).

- [ ] **Step 2: Build**

```
zig build
```

- [ ] **Step 3: Commit**

```bash
git add src/infra/inbound/tui/app.zig
git commit -m "feat(infra/tui): doResume spawns child with task.project_path as cwd"
```

---

## Phase F — Smoke

### Task F1: Extend smoke test

**Files:**
- Modify: `tests/smoke.sh`

- [ ] **Step 1: Append project_path scenario**

After the existing handoff smoke section:

```bash
echo "--- project picker smoke ---"
$BIN add "project smoke" --project /tmp
PID=$($BIN list --json | jq '.[-1].task.id')

# Verify project_path was stored
test "$($BIN context $PID --json | jq -r '.task.project_path')" = "/tmp"

# resume --print still works (cwd setting only affects spawn, not --print)
$BIN session set $PID claude smoke-id-456
$BIN resume $PID --print 2>&1 | grep -q "smoke-id-456"

$BIN delete $PID
echo "project picker smoke OK"
```

- [ ] **Step 2: Run**

```bash
chmod +x tests/smoke.sh
zig build
./tests/smoke.sh
```

Expected: final line `project picker smoke OK`.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke.sh
git commit -m "test: smoke coverage for project_path round-trip"
```

---

## Self-review

**Spec coverage:**
- §4.1 Domain Task/NewTask/TaskPatch → A1 ✓
- §4.2 v3 migration → A2 ✓
- §4.3 Adapter changes → A3 ✓
- §4.4 Application (AddTodo flows through; FakeTaskRepo, freeTask mirror) → A4 ✓
- §5 Add-todo modal (Project field, focus order, key handling, validation) → D1, D3, D4 ✓
- §6 Fuzzy match logic + tests → B1 ✓
- §7 Resume integration (CWD) — CLI + TUI → C2, E2 ✓
- §8 Detail panel display → E1 ✓
- §12 CLI flag → C1 ✓
- §11 Testing strategy → A2 (migration test), A3 (round-trip), B1 (7 helper tests), F1 (smoke). State-machine tests for TUI picker NOT added (acknowledged gap).
- §13 Migration → A2 ✓ (idempotent, default null preserves legacy)

**Placeholder scan:** No "TBD", "TODO", "implement later" in plan body. The C2/E2 spawn-API uncertainty (cwd vs cwd_dir) is acknowledged with a fallback recipe — actionable, not a placeholder.

**Type consistency:**
- `cfg.RepoConfig` referenced in B1, D2, D4 — same type.
- `repo_match.Match`, `repo_match.MAX_RESULTS`, `repo_match.fuzzyMatch` referenced consistently in B1 (definition), D3, D4.
- `state.cfg_repos: []const cfg.RepoConfig` defined in D4, written in D4 (via `run()` init), read in D4 modal render.
- `submitAddTodo` defined in D3; the existing Enter branch in modal must be updated to call it (called out in D3).

**Estimated time:** 4-6 hours.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-03-ctt-project-picker.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task with spec + code reviews.
2. **Inline Execution** — work through tasks in this session with checkpoints.

Which approach?
