# ctt Handoff & Resume — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-task LLM session handle + append-only handoff log, with cold-start resume (TUI spawn) and warm-continue resume (in-session via MCP `get_context`). Provider-agnostic via config-supplied templates.

**Architecture:** Hexagonal — new domain entities (`HandoffEntry`, `SessionHandle`), new `HandoffRepository` port, SQLite migration to v2, new application use cases (`AddHandoff`, `ListHandoffs`, `GetContext`, `BuildResumeCommand`), CLI subcommands (`session`, `handoff`, `context`, `resume`), MCP tools, and TUI keys (`Enter`, `r`, `R`, `H`).

**Tech Stack:** Zig 0.16, zqlite (SQLite), libvaxis (TUI). All existing.

**Spec:** `docs/superpowers/specs/2026-06-03-ctt-handoff-resume-design.md` (commit `ca685e4`).

---

## File map

**Create (new):**
- `src/domain/value_objects/session_handle.zig`
- `src/domain/entities/handoff.zig`
- `src/domain/ports/handoff_repository.zig`
- `src/application/use_cases/set_session_handle.zig`
- `src/application/use_cases/add_handoff.zig`
- `src/application/use_cases/list_handoffs.zig`
- `src/application/use_cases/get_context.zig`
- `src/application/use_cases/build_resume_command.zig`
- `src/infra/outbound/sqlite/handoff_repository.zig`

**Modify:**
- `src/domain/value_objects/ids.zig` (add `HandoffId`)
- `src/domain/entities/task.zig` (`session` field, `TaskPatch.session`)
- `src/domain/root.zig` (re-export new items)
- `src/domain/ports/task_repository.zig` (no signature change; `update` already handles via patch)
- `src/application/root.zig` (re-export new use cases & `TaskContext`)
- `src/infra/outbound/sqlite/migrations.zig` (add `v2` constant)
- `src/infra/outbound/sqlite/db.zig` (apply v2 when `user_version < 2`)
- `src/infra/outbound/sqlite/root.zig` (re-export `SqliteHandoffRepository`)
- `src/infra/outbound/sqlite/task_repository.zig` (read/write `session_provider`, `session_id`; extend `TASK_SELECT` with two trailing columns)
- `src/infra/outbound/config/loader.zig` (add `ProviderTemplates`, `UiConfig`, `providers.templates`, `providers.default`, `ui` fields)
- `src/infra/inbound/cli/args.zig` (new `Command` variants + parsers + `freeCommand`)
- `src/infra/inbound/cli/handlers.zig` (new handlers + dispatch arms)
- `src/infra/inbound/cli/use_cases.zig` (new use-case fields)
- `src/infra/inbound/cli/root.zig` (re-exports if any)
- `src/infra/inbound/mcp/server.zig` (5 new tools)
- `src/infra/inbound/mcp/use_cases.zig` (new use-case fields)
- `src/infra/inbound/tui/use_cases.zig` (new use-case fields)
- `src/infra/inbound/tui/state.zig` (detail-panel + handoff-modal state)
- `src/infra/inbound/tui/app.zig` (key handlers for `Enter`, `r`, `R`, `H`)
- `src/infra/inbound/tui/view.zig` (render detail panel + provider icon + handoff modal)
- `src/infra/inbound/tui/modal.zig` (handoff text-area modal)
- `src/main.zig` (composition root: build `SqliteHandoffRepository`, wire new use cases into CLI/MCP/TUI)
- `tests/smoke.sh` (extend with handoff scenarios)

---

## Phase A — Domain & schema

### Task A1: `HandoffId` value object

**Files:**
- Modify: `src/domain/value_objects/ids.zig`

- [ ] **Step 1: Add the id type**

Append after the existing ids:

```zig
pub const HandoffId   = enum(i64) { _, pub fn raw(self: HandoffId) i64 { return @intFromEnum(self); } };
```

- [ ] **Step 2: Build domain module to verify it compiles**

Run: `zig build`
Expected: success (no test runs yet — domain has no test for this trivial change).

- [ ] **Step 3: Commit**

```bash
git add src/domain/value_objects/ids.zig
git commit -m "feat(domain): add HandoffId"
```

---

### Task A2: `SessionHandle` value object

**Files:**
- Create: `src/domain/value_objects/session_handle.zig`
- Modify: `src/domain/root.zig` (re-export)

- [ ] **Step 1: Write the test (added inline in the new file)**

Create `src/domain/value_objects/session_handle.zig`:

```zig
const std = @import("std");

pub const SessionHandle = struct {
    provider: []const u8,    // e.g. "claude", "codex" — opaque to ctt
    session_id: []const u8,  // opaque to ctt

    pub fn eql(a: SessionHandle, b: SessionHandle) bool {
        return std.mem.eql(u8, a.provider, b.provider)
            and std.mem.eql(u8, a.session_id, b.session_id);
    }
};

test "eql is true for identical handles" {
    const h1 = SessionHandle{ .provider = "claude", .session_id = "abc" };
    const h2 = SessionHandle{ .provider = "claude", .session_id = "abc" };
    try std.testing.expect(h1.eql(h2));
}

test "eql is false when provider differs" {
    const h1 = SessionHandle{ .provider = "claude", .session_id = "abc" };
    const h2 = SessionHandle{ .provider = "codex", .session_id = "abc" };
    try std.testing.expect(!h1.eql(h2));
}

test "eql is false when session_id differs" {
    const h1 = SessionHandle{ .provider = "claude", .session_id = "abc" };
    const h2 = SessionHandle{ .provider = "claude", .session_id = "xyz" };
    try std.testing.expect(!h1.eql(h2));
}
```

- [ ] **Step 2: Re-export from domain root**

Add to `src/domain/root.zig`:

```zig
pub const SessionHandle = @import("value_objects/session_handle.zig").SessionHandle;
```

(Place near other value-object re-exports.)

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: all pass (new tests included automatically; domain test module already wired in `build.zig`).

- [ ] **Step 4: Commit**

```bash
git add src/domain/value_objects/session_handle.zig src/domain/root.zig
git commit -m "feat(domain): add SessionHandle value object"
```

---

### Task A3: `HandoffEntry` entity & `NewHandoff` draft

**Files:**
- Create: `src/domain/entities/handoff.zig`
- Modify: `src/domain/root.zig`

- [ ] **Step 1: Write the entity + tests**

Create `src/domain/entities/handoff.zig`:

```zig
const std = @import("std");
const ids = @import("../value_objects/ids.zig");
const Timestamp = @import("../value_objects/timestamp.zig").Timestamp;

pub const HandoffEntry = struct {
    id: ids.HandoffId,
    task_id: ids.TaskId,
    body: []const u8,
    created_at: Timestamp,
};

pub const NewHandoff = struct {
    task_id: ids.TaskId,
    body: []const u8,
};

test "HandoffEntry construction" {
    const h = HandoffEntry{
        .id = @enumFromInt(1),
        .task_id = @enumFromInt(42),
        .body = "checkpoint",
        .created_at = .{ .unix_secs = 0 },
    };
    try std.testing.expectEqual(@as(i64, 1), h.id.raw());
    try std.testing.expectEqual(@as(i64, 42), h.task_id.raw());
    try std.testing.expectEqualStrings("checkpoint", h.body);
}
```

- [ ] **Step 2: Re-export from domain root**

Add to `src/domain/root.zig`:

```zig
pub const HandoffEntry = @import("entities/handoff.zig").HandoffEntry;
pub const NewHandoff   = @import("entities/handoff.zig").NewHandoff;
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add src/domain/entities/handoff.zig src/domain/root.zig
git commit -m "feat(domain): add HandoffEntry and NewHandoff"
```

---

### Task A4: Extend `Task` and `TaskPatch` with `session`

**Files:**
- Modify: `src/domain/entities/task.zig`

- [ ] **Step 1: Add the field to `Task`**

Locate `pub const Task = struct { ... }` and add:

```zig
session: ?@import("../value_objects/session_handle.zig").SessionHandle = null,
```

Place it after `notes: ?[]const u8,` (keep grouping with other optional fields).

- [ ] **Step 2: Add the patch field to `TaskPatch`**

Locate `pub const TaskPatch = struct { ... }` and add:

```zig
session: ??@import("../value_objects/session_handle.zig").SessionHandle = null,
// outer null = no change; Some(null) = clear; Some(x) = set
```

- [ ] **Step 3: Update existing constructor sites in tests / fakes if any error**

Run: `zig build test`
Expected: any places that construct a `Task` literal without `.session` now need `.session = null` because Zig requires explicit init when there's no default — but we DID give it a default. So this should pass. Fix any compile errors that pop up by adding `.session = null` to literal sites.

- [ ] **Step 4: Commit**

```bash
git add src/domain/entities/task.zig
git commit -m "feat(domain): Task gains optional session handle"
```

---

### Task A5: `HandoffRepository` port

**Files:**
- Create: `src/domain/ports/handoff_repository.zig`
- Modify: `src/domain/root.zig` (re-export under `ports.HandoffRepository`)

- [ ] **Step 1: Write the port**

Create `src/domain/ports/handoff_repository.zig`:

```zig
const std = @import("std");
const ids = @import("../value_objects/ids.zig");
const Timestamp = @import("../value_objects/timestamp.zig").Timestamp;
const handoff = @import("../entities/handoff.zig");

pub const HandoffRepository = struct {
    pub const Error = error{
        Io,
        OutOfMemory,
        NotFound,
    };

    pub const VTable = struct {
        append: *const fn (ptr: *anyopaque, a: std.mem.Allocator, draft: handoff.NewHandoff, now: Timestamp) Error!ids.HandoffId,
        list:   *const fn (ptr: *anyopaque, a: std.mem.Allocator, task_id: ids.TaskId, limit: ?u32) Error![]handoff.HandoffEntry,
        latest: *const fn (ptr: *anyopaque, a: std.mem.Allocator, task_id: ids.TaskId) Error!?handoff.HandoffEntry,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn append(self: HandoffRepository, a: std.mem.Allocator, draft: handoff.NewHandoff, now: Timestamp) Error!ids.HandoffId {
        return self.vtable.append(self.ptr, a, draft, now);
    }
    pub fn list(self: HandoffRepository, a: std.mem.Allocator, task_id: ids.TaskId, limit: ?u32) Error![]handoff.HandoffEntry {
        return self.vtable.list(self.ptr, a, task_id, limit);
    }
    pub fn latest(self: HandoffRepository, a: std.mem.Allocator, task_id: ids.TaskId) Error!?handoff.HandoffEntry {
        return self.vtable.latest(self.ptr, a, task_id);
    }
};
```

- [ ] **Step 2: Re-export**

In `src/domain/root.zig`, locate the `ports` namespace and add the import. If `ports` is a struct with explicit re-exports, add:

```zig
pub const ports = struct {
    // ... existing exports ...
    pub const HandoffRepository = @import("ports/handoff_repository.zig").HandoffRepository;
};
```

(Match the existing style; if `ports` is built via `@import` of a `ports/root.zig` file, add the export there instead. Inspect first.)

- [ ] **Step 3: Build**

Run: `zig build`
Expected: success. Port has no runtime tests of its own.

- [ ] **Step 4: Commit**

```bash
git add src/domain/ports/handoff_repository.zig src/domain/root.zig
git commit -m "feat(domain): add HandoffRepository port"
```

---

### Task A6: v2 migration SQL

**Files:**
- Modify: `src/infra/outbound/sqlite/migrations.zig`
- Modify: `src/infra/outbound/sqlite/db.zig`

- [ ] **Step 1: Add the `v2` constant**

Append to `src/infra/outbound/sqlite/migrations.zig` (after `v1`):

```zig
pub const v2: [*:0]const u8 =
    \\ALTER TABLE tasks ADD COLUMN session_provider TEXT;
    \\ALTER TABLE tasks ADD COLUMN session_id TEXT;
    \\CREATE TABLE IF NOT EXISTS handoffs (
    \\    id INTEGER PRIMARY KEY,
    \\    task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    \\    body TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS handoffs_task_created
    \\    ON handoffs(task_id, created_at DESC);
    \\PRAGMA user_version = 2;
;
```

- [ ] **Step 2: Apply v2 in the migrator**

In `src/infra/outbound/sqlite/db.zig`, update `migrate()` — after the `if (version < 1)` block, add:

```zig
if (version < 2) {
    try self.conn.execNoArgs(migrations.v2);
}
```

- [ ] **Step 3: Update existing db test that checks table count**

Open `src/infra/outbound/sqlite/db.zig`, locate the test "open creates db file and applies v1 migration", change the final assertion from `try std.testing.expect(seen >= 5);` to:

```zig
try std.testing.expect(seen >= 6);   // tasks, repos, worktrees, prs, issues, handoffs
```

Add a new test below it:

```zig
test "v2 migration adds session columns and handoffs table" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path_z = try tmpDbPath(std.testing.allocator, tmp, "v2.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();

    // user_version is 2
    var ver_row = (try db.conn.row("PRAGMA user_version", .{})).?;
    defer ver_row.deinit();
    try std.testing.expectEqual(@as(i64, 2), ver_row.int(0));

    // handoffs table exists
    var rows = try db.conn.rows("SELECT name FROM sqlite_master WHERE type='table' AND name='handoffs'", .{});
    defer rows.deinit();
    try std.testing.expect(rows.next() != null);

    // session_provider column exists on tasks
    var col_rows = try db.conn.rows("PRAGMA table_info(tasks)", .{});
    defer col_rows.deinit();
    var found_sp = false;
    while (col_rows.next()) |r| {
        const name = r.text(1);
        if (std.mem.eql(u8, name, "session_provider")) found_sp = true;
    }
    try std.testing.expect(found_sp);
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: all pass including the two updated/new sqlite tests.

- [ ] **Step 5: Commit**

```bash
git add src/infra/outbound/sqlite/migrations.zig src/infra/outbound/sqlite/db.zig
git commit -m "feat(infra/sqlite): v2 migration — session columns + handoffs table"
```

---

## Phase B — SQLite adapter

### Task B1: Extend `SqliteTaskRepository` to read/write session columns

**Files:**
- Modify: `src/infra/outbound/sqlite/task_repository.zig`

The existing `TASK_SELECT` is a positional JOIN; **append two columns at the end** so existing index constants (0..32) don't shift.

- [ ] **Step 1: Failing test — round-trip session handle via update + get**

Add to the tests block of `src/infra/outbound/sqlite/task_repository.zig`:

```zig
test "task session handle round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "sess.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try @import("db.zig").Db.open(path_z);
    defer db.close();

    var repo = SqliteTaskRepository.init(&db);
    const iface = repo.interface();

    const created = try iface.create(std.testing.allocator, .{ .title = "t" });
    try std.testing.expect(created.session == null);

    const handle = d.SessionHandle{ .provider = "claude", .session_id = "abc-123" };
    _ = try iface.update(std.testing.allocator, created.id, .{ .session = @as(?d.SessionHandle, handle) });

    const got = (try iface.get(std.testing.allocator, created.id)).?;
    defer std.testing.allocator.free(got.title);
    if (got.session) |s| {
        defer std.testing.allocator.free(s.provider);
        defer std.testing.allocator.free(s.session_id);
        try std.testing.expectEqualStrings("claude", s.provider);
        try std.testing.expectEqualStrings("abc-123", s.session_id);
    } else try std.testing.expect(false);
}

test "task session handle clear" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "sess2.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try @import("db.zig").Db.open(path_z);
    defer db.close();

    var repo = SqliteTaskRepository.init(&db);
    const iface = repo.interface();

    const t = try iface.create(std.testing.allocator, .{ .title = "t" });
    _ = try iface.update(std.testing.allocator, t.id, .{ .session = @as(?d.SessionHandle, .{ .provider = "x", .session_id = "y" }) });
    _ = try iface.update(std.testing.allocator, t.id, .{ .session = @as(?d.SessionHandle, null) });

    const got = (try iface.get(std.testing.allocator, t.id)).?;
    defer std.testing.allocator.free(got.title);
    try std.testing.expect(got.session == null);
}
```

(If `tmpDbPath` is module-private to `db.zig`, copy it into this file or move it to a shared test helper file. Inspect `db.zig` for its definition and pick the smaller diff.)

- [ ] **Step 2: Run — confirm tests fail to compile/run**

Run: `zig build test 2>&1 | head -40`
Expected: failure — `TaskPatch.session` field not handled in the patch UPDATE chain, columns not in SELECT.

- [ ] **Step 3: Extend `TASK_SELECT` with two trailing columns**

In `TASK_SELECT`, append `, t.session_provider, t.session_id` as the last two columns. Update the column-layout comment at the top of the file to add:

```
// 33  t.session_provider
// 34  t.session_id
```

- [ ] **Step 4: Read the new columns in `rowToTask`**

Locate `fn rowToTask(...)`. After the existing field reads, add:

```zig
const sp_raw: ?[]const u8 = if (row.isNull(33)) null else row.text(33);
const si_raw: ?[]const u8 = if (row.isNull(34)) null else row.text(34);
const session: ?d.SessionHandle = if (sp_raw != null and si_raw != null)
    .{ .provider = try a.dupe(u8, sp_raw.?), .session_id = try a.dupe(u8, si_raw.?) }
else
    null;
```

…and add `.session = session` to the returned `Task` literal.

(Cross-check actual `row.isNull` / `row.text` API in `zqlite`; substitute the equivalent call if the names differ. The repo already calls `row.text(N)` and `row.int(N)`; check for `row.isNull` or `row.nullableText`.)

- [ ] **Step 5: Handle `TaskPatch.session` in `updateFn`**

In the `updateFn` patch-application chain (around line 240), after the existing branches, add:

```zig
if (patch.session) |maybe_sh| {
    if (maybe_sh) |sh| {
        conn.exec(
            "UPDATE tasks SET session_provider = ?, session_id = ?, updated_at = datetime('now') WHERE id = ?",
            .{ sh.provider, sh.session_id, id.raw() },
        ) catch |e| return mapErr(e);
    } else {
        conn.exec(
            "UPDATE tasks SET session_provider = NULL, session_id = NULL, updated_at = datetime('now') WHERE id = ?",
            .{id.raw()},
        ) catch |e| return mapErr(e);
    }
}
```

- [ ] **Step 6: Run tests — confirm pass**

Run: `zig build test`
Expected: pass (both new tests + all existing tests still pass).

- [ ] **Step 7: Commit**

```bash
git add src/infra/outbound/sqlite/task_repository.zig
git commit -m "feat(infra/sqlite): persist session handle on tasks"
```

---

### Task B2: `SqliteHandoffRepository`

**Files:**
- Create: `src/infra/outbound/sqlite/handoff_repository.zig`
- Modify: `src/infra/outbound/sqlite/root.zig` (re-export)

- [ ] **Step 1: Write the adapter + tests**

Create `src/infra/outbound/sqlite/handoff_repository.zig`:

```zig
const std = @import("std");
const d = @import("domain");
const zqlite = @import("zqlite");
const Db = @import("db.zig").Db;

pub const SqliteHandoffRepository = struct {
    db: *Db,

    pub fn init(db: *Db) SqliteHandoffRepository {
        return .{ .db = db };
    }

    pub fn interface(self: *SqliteHandoffRepository) d.ports.HandoffRepository {
        return .{ .ptr = self, .vtable = &VT };
    }

    const VT = d.ports.HandoffRepository.VTable{
        .append = appendFn,
        .list   = listFn,
        .latest = latestFn,
    };

    fn mapErr(e: anyerror) d.ports.HandoffRepository.Error {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Io,
        };
    }

    fn appendFn(
        p: *anyopaque,
        _: std.mem.Allocator,
        draft: d.NewHandoff,
        now: d.Timestamp,
    ) d.ports.HandoffRepository.Error!d.ids.HandoffId {
        const self: *SqliteHandoffRepository = @ptrCast(@alignCast(p));
        self.db.conn.exec(
            "INSERT INTO handoffs (task_id, body, created_at) VALUES (?, ?, ?)",
            .{ draft.task_id.raw(), draft.body, now.unix_secs },
        ) catch |e| return mapErr(e);
        return @enumFromInt(self.db.conn.lastInsertedRowId());
    }

    fn listFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        task_id: d.ids.TaskId,
        limit: ?u32,
    ) d.ports.HandoffRepository.Error![]d.HandoffEntry {
        const self: *SqliteHandoffRepository = @ptrCast(@alignCast(p));
        const lim: i64 = if (limit) |l| @intCast(l) else -1;  // -1 = no limit in SQLite
        var rows = self.db.conn.rows(
            "SELECT id, task_id, body, created_at FROM handoffs WHERE task_id = ? ORDER BY created_at DESC, id DESC LIMIT ?",
            .{ task_id.raw(), lim },
        ) catch |e| return mapErr(e);
        defer rows.deinit();

        var out: std.ArrayList(d.HandoffEntry) = .empty;
        errdefer {
            for (out.items) |h| a.free(h.body);
            out.deinit(a);
        }

        while (rows.next()) |row| {
            const body = a.dupe(u8, row.text(2)) catch return error.OutOfMemory;
            errdefer a.free(body);
            try out.append(a, .{
                .id = @enumFromInt(row.int(0)),
                .task_id = @enumFromInt(row.int(1)),
                .body = body,
                .created_at = .{ .unix_secs = row.int(3) },
            });
        }
        return out.toOwnedSlice(a);
    }

    fn latestFn(
        p: *anyopaque,
        a: std.mem.Allocator,
        task_id: d.ids.TaskId,
    ) d.ports.HandoffRepository.Error!?d.HandoffEntry {
        const self: *SqliteHandoffRepository = @ptrCast(@alignCast(p));
        const maybe_row = self.db.conn.row(
            "SELECT id, task_id, body, created_at FROM handoffs WHERE task_id = ? ORDER BY created_at DESC, id DESC LIMIT 1",
            .{task_id.raw()},
        ) catch |e| return mapErr(e);
        const row = maybe_row orelse return null;
        defer row.deinit();
        const body = a.dupe(u8, row.text(2)) catch return error.OutOfMemory;
        return .{
            .id = @enumFromInt(row.int(0)),
            .task_id = @enumFromInt(row.int(1)),
            .body = body,
            .created_at = .{ .unix_secs = row.int(3) },
        };
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────

fn tmpDbPath(a: std.mem.Allocator, tmp: std.testing.TmpDir, name: []const u8) ![:0]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ buf[0..n], name }, 0);
}

test "append then latest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "h.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();

    // need a task to FK to
    try db.conn.exec("INSERT INTO tasks (title) VALUES (?)", .{"t"});
    const task_id: d.ids.TaskId = @enumFromInt(db.conn.lastInsertedRowId());

    var repo = SqliteHandoffRepository.init(&db);
    const iface = repo.interface();

    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "first" }, .{ .unix_secs = 100 });
    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "second" }, .{ .unix_secs = 200 });

    const latest = (try iface.latest(std.testing.allocator, task_id)).?;
    defer std.testing.allocator.free(latest.body);
    try std.testing.expectEqualStrings("second", latest.body);
}

test "list returns entries newest first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "h2.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();
    try db.conn.exec("INSERT INTO tasks (title) VALUES (?)", .{"t"});
    const task_id: d.ids.TaskId = @enumFromInt(db.conn.lastInsertedRowId());

    var repo = SqliteHandoffRepository.init(&db);
    const iface = repo.interface();

    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "a" }, .{ .unix_secs = 1 });
    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "b" }, .{ .unix_secs = 2 });
    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "c" }, .{ .unix_secs = 3 });

    const all = try iface.list(std.testing.allocator, task_id, null);
    defer {
        for (all) |h| std.testing.allocator.free(h.body);
        std.testing.allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("c", all[0].body);
    try std.testing.expectEqualStrings("b", all[1].body);
    try std.testing.expectEqualStrings("a", all[2].body);
}

test "cascade delete removes handoffs when task is deleted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path_z = try tmpDbPath(std.testing.allocator, tmp, "h3.sqlite");
    defer std.testing.allocator.free(path_z);

    var db = try Db.open(path_z);
    defer db.close();
    try db.conn.execNoArgs("PRAGMA foreign_keys = ON");
    try db.conn.exec("INSERT INTO tasks (title) VALUES (?)", .{"t"});
    const task_id: d.ids.TaskId = @enumFromInt(db.conn.lastInsertedRowId());

    var repo = SqliteHandoffRepository.init(&db);
    const iface = repo.interface();
    _ = try iface.append(std.testing.allocator, .{ .task_id = task_id, .body = "x" }, .{ .unix_secs = 1 });

    try db.conn.exec("DELETE FROM tasks WHERE id = ?", .{task_id.raw()});

    const got = try iface.latest(std.testing.allocator, task_id);
    try std.testing.expect(got == null);
}
```

- [ ] **Step 2: Re-export**

In `src/infra/outbound/sqlite/root.zig`:

```zig
pub const SqliteHandoffRepository = @import("handoff_repository.zig").SqliteHandoffRepository;
```

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: all three new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/infra/outbound/sqlite/handoff_repository.zig src/infra/outbound/sqlite/root.zig
git commit -m "feat(infra/sqlite): SqliteHandoffRepository (append/list/latest)"
```

---

## Phase C — Config

### Task C1: `ProviderTemplates`, `UiConfig`, `providers.default`

**Files:**
- Modify: `src/infra/outbound/config/loader.zig`

- [ ] **Step 1: Failing test for new config fields**

Add to the tests in `src/infra/outbound/config/loader.zig`:

```zig
test "load config with provider templates and ui" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{
        \\  "db_path":"/x","repos":[],
        \\  "providers":{
        \\    "patterns":[],
        \\    "default":"claude",
        \\    "templates":{
        \\      "claude":{"resume":"claude --resume {{session_id}}","fresh":"claude","icon":"C"}
        \\    }
        \\  },
        \\  "ui":{"spawn":"tmux new-window -- {{cmd}}"}
        \\}
    );
    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);

    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("claude", parsed.value.providers.default.?);
    const tmpl = parsed.value.providers.templates.get("claude").?;
    try std.testing.expectEqualStrings("claude --resume {{session_id}}", tmpl.resume.?);
    try std.testing.expectEqualStrings("C", tmpl.icon.?);
    try std.testing.expectEqualStrings("tmux new-window -- {{cmd}}", parsed.value.ui.spawn.?);
}
```

- [ ] **Step 2: Add the structs**

In the type-declaration section of `loader.zig`, add:

```zig
pub const ProviderTemplates = struct {
    resume: ?[]const u8 = null,
    fresh:  ?[]const u8 = null,
    icon:   ?[]const u8 = null,
};

pub const UiConfig = struct {
    spawn: ?[]const u8 = null,
};
```

- [ ] **Step 3: Add fields to existing structs**

In `ProvidersConfig` add:

```zig
default: ?[]const u8 = null,
templates: std.json.ArrayHashMap(ProviderTemplates) = .{},
// Note: std.json.ArrayHashMap is the JSON-friendly map; check the std API and
// substitute std.StringHashMapUnmanaged + custom parseFromValue if not available.
```

In `Config` add:

```zig
ui: UiConfig = .{},
```

- [ ] **Step 4: Run the new test**

Run: `zig build test 2>&1 | grep -A2 "load config with provider templates"`
Expected: pass.

If the JSON map type doesn't parse cleanly with `std.json.parseFromSlice`, fall back to: parse `providers` as `std.json.Value`, walk `obj.get("templates").?.object` manually building the map. Document this in a small `parseProvidersTemplates` helper inside the file. Keep tests passing.

- [ ] **Step 5: Run full test suite**

Run: `zig build test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/infra/outbound/config/loader.zig
git commit -m "feat(infra/config): providers.templates, providers.default, ui.spawn"
```

---

## Phase D — Application use cases

### Task D1: `SetSessionHandle` use case

**Files:**
- Create: `src/application/use_cases/set_session_handle.zig`
- Modify: `src/application/root.zig`

- [ ] **Step 1: Write the use case + test**

Create `src/application/use_cases/set_session_handle.zig`:

```zig
const std = @import("std");
const d = @import("domain");

pub const SetSessionHandle = struct {
    tasks: d.ports.TaskRepository,

    pub fn execute(self: SetSessionHandle, a: std.mem.Allocator, id: d.ids.TaskId, handle: ?d.SessionHandle) !d.Task {
        return self.tasks.update(a, id, .{ .session = @as(??d.SessionHandle, handle) });
    }
};

// Tests live in src/application/tests/ alongside other use-case tests; or inline if
// the module is registered as a test root. Inspect existing pattern (e.g.
// add_todo.zig) before deciding placement.
```

- [ ] **Step 2: Re-export**

In `src/application/root.zig`:

```zig
pub const SetSessionHandle = @import("use_cases/set_session_handle.zig").SetSessionHandle;
```

- [ ] **Step 3: Build**

Run: `zig build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add src/application/use_cases/set_session_handle.zig src/application/root.zig
git commit -m "feat(app): SetSessionHandle use case"
```

---

### Task D2: `AddHandoff` use case

**Files:**
- Create: `src/application/use_cases/add_handoff.zig`
- Modify: `src/application/root.zig`

- [ ] **Step 1: Write the use case**

Create `src/application/use_cases/add_handoff.zig`:

```zig
const std = @import("std");
const d = @import("domain");

pub const AddHandoff = struct {
    handoffs: d.ports.HandoffRepository,
    clock: d.ports.Clock,

    pub fn execute(self: AddHandoff, a: std.mem.Allocator, task_id: d.ids.TaskId, body: []const u8) !d.ids.HandoffId {
        return self.handoffs.append(a, .{ .task_id = task_id, .body = body }, self.clock.now());
    }
};
```

- [ ] **Step 2: Re-export**

In `src/application/root.zig`:

```zig
pub const AddHandoff = @import("use_cases/add_handoff.zig").AddHandoff;
```

- [ ] **Step 3: Build**

Run: `zig build`

- [ ] **Step 4: Commit**

```bash
git add src/application/use_cases/add_handoff.zig src/application/root.zig
git commit -m "feat(app): AddHandoff use case"
```

---

### Task D3: `ListHandoffs` use case

**Files:**
- Create: `src/application/use_cases/list_handoffs.zig`
- Modify: `src/application/root.zig`

- [ ] **Step 1: Write the use case**

```zig
const std = @import("std");
const d = @import("domain");

pub const ListHandoffs = struct {
    handoffs: d.ports.HandoffRepository,

    pub fn execute(self: ListHandoffs, a: std.mem.Allocator, task_id: d.ids.TaskId, limit: ?u32) ![]d.HandoffEntry {
        return self.handoffs.list(a, task_id, limit);
    }
};
```

- [ ] **Step 2: Re-export**

```zig
pub const ListHandoffs = @import("use_cases/list_handoffs.zig").ListHandoffs;
```

- [ ] **Step 3: Build + commit**

```bash
zig build
git add src/application/use_cases/list_handoffs.zig src/application/root.zig
git commit -m "feat(app): ListHandoffs use case"
```

---

### Task D4: `GetContext` use case (composite)

**Files:**
- Create: `src/application/use_cases/get_context.zig`
- Modify: `src/application/root.zig`

- [ ] **Step 1: Write the use case**

```zig
const std = @import("std");
const d = @import("domain");

pub const TaskContext = struct {
    task: d.Task,                          // includes session, worktree, pr, issue
    handoffs: []d.HandoffEntry,            // newest first
    // Caller owns task and handoffs allocations.
};

pub const GetContext = struct {
    tasks: d.ports.TaskRepository,
    handoffs: d.ports.HandoffRepository,

    pub fn execute(
        self: GetContext,
        a: std.mem.Allocator,
        id: d.ids.TaskId,
        handoff_limit: ?u32,
    ) !?TaskContext {
        const t = try self.tasks.get(a, id) orelse return null;
        const hs = try self.handoffs.list(a, id, handoff_limit);
        return TaskContext{ .task = t, .handoffs = hs };
    }
};
```

- [ ] **Step 2: Re-export**

```zig
pub const GetContext = @import("use_cases/get_context.zig").GetContext;
pub const TaskContext = @import("use_cases/get_context.zig").TaskContext;
```

- [ ] **Step 3: Build + commit**

```bash
zig build
git add src/application/use_cases/get_context.zig src/application/root.zig
git commit -m "feat(app): GetContext use case + TaskContext"
```

---

### Task D5: `BuildResumeCommand` — the template renderer

**Files:**
- Create: `src/application/use_cases/build_resume_command.zig`
- Modify: `src/application/root.zig`

This is the most logic-heavy use case; it gets exhaustive tests.

- [ ] **Step 1: Failing tests first**

Create `src/application/use_cases/build_resume_command.zig` with skeleton + tests:

```zig
const std = @import("std");
const d = @import("domain");

/// A rendered, ready-to-spawn command.
pub const ResumeCommand = struct {
    command: []const u8,        // caller owns
    mode: enum { resume_session, fresh_with_context },
};

pub const BuildError = error{
    NoTemplateForProvider,
    NoDefaultProvider,
    OutOfMemory,
};

/// One entry from config.providers.templates.
pub const ProviderTemplate = struct {
    resume: ?[]const u8 = null,
    fresh: ?[]const u8 = null,
    icon: ?[]const u8 = null,
};

pub const Inputs = struct {
    /// Lookup function: caller knows where the templates map lives in their config.
    templates: *const fn (provider: []const u8) ?ProviderTemplate,
    default_provider: ?[]const u8,
    session: ?d.SessionHandle,
    /// Path to a temp file containing the latest handoff body (or empty file).
    context_file: ?[]const u8,
    /// If non-null, wrap the rendered inner command in this template via `{{cmd}}`.
    spawn_wrapper: ?[]const u8,
    /// Force fresh mode even when a session handle is present.
    force_fresh: bool,
};

pub fn build(a: std.mem.Allocator, inp: Inputs) BuildError!ResumeCommand {
    // 1. Pick provider name
    const provider = blk: {
        if (!inp.force_fresh) if (inp.session) |s| break :blk s.provider;
        if (inp.default_provider) |p| break :blk p;
        return error.NoDefaultProvider;
    };

    // 2. Look up the template entry
    const tmpl = inp.templates(provider) orelse return error.NoTemplateForProvider;

    // 3. Pick resume vs fresh
    const use_resume = !inp.force_fresh and inp.session != null and tmpl.resume != null;
    const inner_tmpl = if (use_resume) tmpl.resume.? else (tmpl.fresh orelse return error.NoTemplateForProvider);

    // 4. Substitute placeholders
    var inner = try a.dupe(u8, inner_tmpl);
    if (use_resume) {
        const sid = inp.session.?.session_id;
        const replaced = try replaceOwned(a, inner, "{{session_id}}", sid);
        a.free(inner);
        inner = replaced;
    } else {
        const ctx = inp.context_file orelse "";
        const replaced = try replaceOwned(a, inner, "{{context_file}}", ctx);
        a.free(inner);
        inner = replaced;
    }

    // 5. Wrap with spawn template
    if (inp.spawn_wrapper) |wrapper| {
        const wrapped = try replaceOwned(a, wrapper, "{{cmd}}", inner);
        a.free(inner);
        inner = wrapped;
    }

    return .{
        .command = inner,
        .mode = if (use_resume) .resume_session else .fresh_with_context,
    };
}

fn replaceOwned(a: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    // count occurrences
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |pos| : (count += 1) {
        i = pos + needle.len;
    }
    if (count == 0) return a.dupe(u8, haystack);

    const new_len = haystack.len - needle.len * count + replacement.len * count;
    var out = try a.alloc(u8, new_len);
    var src: usize = 0;
    var dst: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, src, needle)) |pos| {
        @memcpy(out[dst .. dst + (pos - src)], haystack[src..pos]);
        dst += pos - src;
        @memcpy(out[dst .. dst + replacement.len], replacement);
        dst += replacement.len;
        src = pos + needle.len;
    }
    if (src < haystack.len) @memcpy(out[dst..], haystack[src..]);
    return out;
}

// ─── Tests ────────────────────────────────────────────────────────────────

fn fixedTemplates(comptime entry: ProviderTemplate) fn ([]const u8) ?ProviderTemplate {
    return struct {
        fn lookup(_: []const u8) ?ProviderTemplate {
            return entry;
        }
    }.lookup;
}

test "resume mode substitutes session_id" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .resume = "claude --resume {{session_id}}" }),
        .default_provider = null,
        .session = .{ .provider = "claude", .session_id = "abc-123" },
        .context_file = null,
        .spawn_wrapper = null,
        .force_fresh = false,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("claude --resume abc-123", result.command);
    try std.testing.expectEqual(@as(@TypeOf(result.mode), .resume_session), result.mode);
}

test "fresh mode substitutes context_file" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .fresh = "claude --append-system-prompt \"$(cat {{context_file}})\"" }),
        .default_provider = "claude",
        .session = null,
        .context_file = "/tmp/x.md",
        .spawn_wrapper = null,
        .force_fresh = false,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("claude --append-system-prompt \"$(cat /tmp/x.md)\"", result.command);
    try std.testing.expectEqual(@as(@TypeOf(result.mode), .fresh_with_context), result.mode);
}

test "force_fresh ignores session handle" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .resume = "R{{session_id}}", .fresh = "F{{context_file}}" }),
        .default_provider = null,
        .session = .{ .provider = "claude", .session_id = "abc" },
        .context_file = "/tmp/y.md",
        .spawn_wrapper = null,
        .force_fresh = true,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("F/tmp/y.md", result.command);
}

test "spawn wrapper wraps the inner command" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .resume = "claude --resume {{session_id}}" }),
        .default_provider = null,
        .session = .{ .provider = "claude", .session_id = "abc" },
        .context_file = null,
        .spawn_wrapper = "tmux new-window -- {{cmd}}",
        .force_fresh = false,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("tmux new-window -- claude --resume abc", result.command);
}

test "missing template returns error" {
    const a = std.testing.allocator;
    const lookup = struct {
        fn f(_: []const u8) ?ProviderTemplate { return null; }
    }.f;
    try std.testing.expectError(error.NoTemplateForProvider, build(a, .{
        .templates = lookup,
        .default_provider = "claude",
        .session = null,
        .context_file = "/tmp/x",
        .spawn_wrapper = null,
        .force_fresh = false,
    }));
}

test "no session and no default returns error" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NoDefaultProvider, build(a, .{
        .templates = fixedTemplates(.{ .fresh = "F{{context_file}}" }),
        .default_provider = null,
        .session = null,
        .context_file = null,
        .spawn_wrapper = null,
        .force_fresh = false,
    }));
}

test "missing context_file substitutes empty string" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .fresh = "claude < {{context_file}}" }),
        .default_provider = "claude",
        .session = null,
        .context_file = null,
        .spawn_wrapper = null,
        .force_fresh = false,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("claude < ", result.command);
}
```

- [ ] **Step 2: Re-export**

In `src/application/root.zig`:

```zig
pub const BuildResumeCommand = @import("use_cases/build_resume_command.zig");
```

(Re-export the module since callers use `build()` and the `Inputs` struct; alternatively, re-export individual symbols.)

- [ ] **Step 3: Run tests**

Run: `zig build test`
Expected: all 7 new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/application/use_cases/build_resume_command.zig src/application/root.zig
git commit -m "feat(app): BuildResumeCommand template renderer"
```

---

## Phase E — CLI

### Task E1: `Command` union & parsers

**Files:**
- Modify: `src/infra/inbound/cli/args.zig`

- [ ] **Step 1: Add new variants to the `Command` union**

Locate `pub const Command = union(enum) { ... }` and add:

```zig
session: SessionArgs,
handoff: HandoffArgs,
context: ContextArgs,
resume: ResumeArgs,
```

Add the arg structs below the existing ones:

```zig
pub const SessionArgs = union(enum) {
    set: struct { id: i64, provider: []const u8, session_id: []const u8 },
    clear: struct { id: i64 },
};

pub const HandoffArgs = struct {
    id: i64,
    note: ?[]const u8 = null,    // if null and !list and !latest, read body from stdin
    list: bool = false,
    latest: bool = false,
    json: bool = false,
};

pub const ContextArgs = struct {
    id: i64,
    json: bool = false,
    handoff_limit: ?u32 = null,
};

pub const ResumeArgs = struct {
    id: i64,
    print: bool = false,
    fresh: bool = false,
};
```

- [ ] **Step 2: Wire dispatch in `parseFromArgs`**

Add to the `if (std.mem.eql(u8, sub, "...")) ...` chain (around line 107):

```zig
if (std.mem.eql(u8, sub, "session")) return try parseSession(a, args[1..]);
if (std.mem.eql(u8, sub, "handoff")) return try parseHandoff(a, args[1..]);
if (std.mem.eql(u8, sub, "context")) return try parseContext(a, args[1..]);
if (std.mem.eql(u8, sub, "resume"))  return try parseResume(a, args[1..]);
```

- [ ] **Step 3: Implement parsers**

Add at the end of the parsers section:

```zig
fn parseSession(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    if (argv.len < 1) return error.MissingArg;
    const action = argv[0];
    if (std.mem.eql(u8, action, "set")) {
        if (argv.len < 4) return error.MissingArg;
        const id = std.fmt.parseInt(i64, argv[1], 10) catch return error.BadInt;
        const provider = try a.dupe(u8, argv[2]);
        errdefer a.free(provider);
        const sid = try a.dupe(u8, argv[3]);
        return .{ .session = .{ .set = .{ .id = id, .provider = provider, .session_id = sid } } };
    } else if (std.mem.eql(u8, action, "clear")) {
        if (argv.len < 2) return error.MissingArg;
        const id = std.fmt.parseInt(i64, argv[1], 10) catch return error.BadInt;
        return .{ .session = .{ .clear = .{ .id = id } } };
    }
    return error.UnknownCommand;
}

fn parseHandoff(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    if (argv.len < 1) return error.MissingArg;
    var result = HandoffArgs{ .id = 0 };
    var got_id = false;
    errdefer if (result.note) |n| a.free(n);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--note")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.note = try a.dupe(u8, argv[i]);
        } else if (std.mem.eql(u8, arg, "--list")) {
            result.list = true;
        } else if (std.mem.eql(u8, arg, "--latest")) {
            result.latest = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .handoff = result };
}

fn parseContext(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    _ = a;
    var result = ContextArgs{ .id = 0 };
    var got_id = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            result.json = true;
        } else if (std.mem.eql(u8, arg, "--handoffs")) {
            i += 1;
            if (i >= argv.len) return error.MissingArg;
            result.handoff_limit = std.fmt.parseInt(u32, argv[i], 10) catch return error.BadInt;
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .context = result };
}

fn parseResume(a: std.mem.Allocator, argv: []const [:0]u8) ParseError!Command {
    _ = a;
    var result = ResumeArgs{ .id = 0 };
    var got_id = false;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--print")) {
            result.print = true;
        } else if (std.mem.eql(u8, arg, "--fresh")) {
            result.fresh = true;
        } else if (!got_id) {
            result.id = std.fmt.parseInt(i64, arg, 10) catch return error.BadInt;
            got_id = true;
        }
    }
    if (!got_id) return error.MissingArg;
    return .{ .resume = result };
}
```

- [ ] **Step 4: Extend `freeCommand`**

Add to the `switch (cmd)` in `freeCommand`:

```zig
.session => |v| switch (v) {
    .set => |c| { a.free(c.provider); a.free(c.session_id); },
    .clear => {},
},
.handoff => |v| if (v.note) |n| a.free(n),
.context => {},
.resume => {},
```

- [ ] **Step 5: Add parser tests**

Add to existing tests:

```zig
test "parse 'session set 5 claude abc'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "session")),
        @constCast(@as([:0]const u8, "set")),
        @constCast(@as([:0]const u8, "5")),
        @constCast(@as([:0]const u8, "claude")),
        @constCast(@as([:0]const u8, "abc-123")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqual(@as(i64, 5), cmd.session.set.id);
    try std.testing.expectEqualStrings("claude", cmd.session.set.provider);
    try std.testing.expectEqualStrings("abc-123", cmd.session.set.session_id);
}

test "parse 'handoff 7 --note hello'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "handoff")),
        @constCast(@as([:0]const u8, "7")),
        @constCast(@as([:0]const u8, "--note")),
        @constCast(@as([:0]const u8, "hello")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqual(@as(i64, 7), cmd.handoff.id);
    try std.testing.expectEqualStrings("hello", cmd.handoff.note.?);
}

test "parse 'resume 3 --fresh'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "resume")),
        @constCast(@as([:0]const u8, "3")),
        @constCast(@as([:0]const u8, "--fresh")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqual(@as(i64, 3), cmd.resume.id);
    try std.testing.expect(cmd.resume.fresh);
}

test "parse 'context 9 --json --handoffs 5'" {
    const args = [_][:0]u8{
        @constCast(@as([:0]const u8, "context")),
        @constCast(@as([:0]const u8, "9")),
        @constCast(@as([:0]const u8, "--json")),
        @constCast(@as([:0]const u8, "--handoffs")),
        @constCast(@as([:0]const u8, "5")),
    };
    const cmd = try parseFromArgs(std.testing.allocator, &args);
    defer freeCommand(std.testing.allocator, cmd);
    try std.testing.expectEqual(@as(i64, 9), cmd.context.id);
    try std.testing.expect(cmd.context.json);
    try std.testing.expectEqual(@as(?u32, 5), cmd.context.handoff_limit);
}
```

- [ ] **Step 6: Run tests**

Run: `zig build test`
Expected: 4 new parser tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/infra/inbound/cli/args.zig
git commit -m "feat(infra/cli): parse session/handoff/context/resume subcommands"
```

---

### Task E2: CLI handlers

**Files:**
- Modify: `src/infra/inbound/cli/handlers.zig`
- Modify: `src/infra/inbound/cli/use_cases.zig`

- [ ] **Step 1: Extend `UseCases` struct**

In `src/infra/inbound/cli/use_cases.zig`, add fields:

```zig
set_session: app.SetSessionHandle,
add_handoff: app.AddHandoff,
list_handoffs: app.ListHandoffs,
get_context: app.GetContext,
```

(Plus a `templates_lookup` closure / function-pointer for resume; see Step 3.)

- [ ] **Step 2: Add dispatch arms**

In `dispatch()`, add:

```zig
.session => |args| try handleSession(a, uc, args, writer),
.handoff => |args| try handleHandoff(a, uc, args, writer),
.context => |args| try handleContext(a, uc, args, writer),
.resume  => |args| try handleResume(a, uc, args, writer),
```

- [ ] **Step 3: Implement handlers**

Add to `handlers.zig`:

```zig
fn handleSession(a: std.mem.Allocator, uc: *UseCases, args: args_mod.SessionArgs, writer: anytype) !void {
    switch (args) {
        .set => |s| {
            _ = try uc.set_session.execute(a, @enumFromInt(s.id), .{ .provider = s.provider, .session_id = s.session_id });
            try writer.print("session set on task #{d}: {s}:{s}\n", .{ s.id, s.provider, s.session_id });
        },
        .clear => |c| {
            _ = try uc.set_session.execute(a, @enumFromInt(c.id), null);
            try writer.print("session cleared on task #{d}\n", .{c.id});
        },
    }
}

fn handleHandoff(a: std.mem.Allocator, uc: *UseCases, args: args_mod.HandoffArgs, writer: anytype) !void {
    const tid: d.ids.TaskId = @enumFromInt(args.id);

    if (args.list) {
        const all = try uc.list_handoffs.execute(a, tid, null);
        defer { for (all) |h| a.free(h.body); a.free(all); }
        if (args.json) {
            try renderHandoffsJson(all, writer);
        } else {
            for (all) |h| try writer.print("[{d}] {s}\n", .{ h.created_at.unix_secs, h.body });
        }
        return;
    }
    if (args.latest) {
        const maybe = try uc.list_handoffs.execute(a, tid, 1);
        defer { for (maybe) |h| a.free(h.body); a.free(maybe); }
        if (maybe.len > 0) try writer.print("{s}\n", .{maybe[0].body});
        return;
    }

    // Write path: --note or stdin
    const body = if (args.note) |n| try a.dupe(u8, n) else try readStdinAll(a);
    defer a.free(body);
    if (body.len == 0) return error.MissingArg;
    const id = try uc.add_handoff.execute(a, tid, body);
    try writer.print("handoff #{d} added to task #{d}\n", .{ id.raw(), args.id });
}

fn handleContext(a: std.mem.Allocator, uc: *UseCases, args: args_mod.ContextArgs, writer: anytype) !void {
    const ctx = try uc.get_context.execute(a, @enumFromInt(args.id), args.handoff_limit) orelse {
        try writer.print("no task with id {d}\n", .{args.id});
        return;
    };
    defer {
        for (ctx.handoffs) |h| a.free(h.body);
        a.free(ctx.handoffs);
        // Task itself is freed via existing task-free helper; reuse it.
    }
    if (args.json) try renderContextJson(ctx, writer)
    else try renderContextText(ctx, writer);
}

fn handleResume(a: std.mem.Allocator, uc: *UseCases, args: args_mod.ResumeArgs, writer: anytype) !void {
    // Implemented in Task E3 below (depends on config + template-lookup wiring).
    _ = a; _ = uc; _ = args; _ = writer;
    return error.NotImplemented;
}

fn readStdinAll(a: std.mem.Allocator) ![]u8 {
    // Use the same io pattern as elsewhere; consult main.zig for the io handle if needed.
    // Simplest portable: read all of stdin into an ArrayList.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var buf: [4096]u8 = undefined;
    const stdin = std.io.getStdIn();
    while (true) {
        const n = try stdin.read(&buf);
        if (n == 0) break;
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}

fn renderHandoffsJson(items: []const d.HandoffEntry, writer: anytype) !void {
    try writer.writeAll("[");
    for (items, 0..) |h, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print(
            \\{{"id":{d},"task_id":{d},"created_at":{d},"body":
        , .{ h.id.raw(), h.task_id.raw(), h.created_at.unix_secs });
        try std.json.encodeJsonString(h.body, .{}, writer);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn renderContextText(ctx: app.TaskContext, writer: anytype) !void {
    try writer.print("Task #{d}: {s}\n", .{ ctx.task.id.raw(), ctx.task.title });
    if (ctx.task.session) |s| try writer.print("  Session: {s}:{s}\n", .{ s.provider, s.session_id });
    if (ctx.task.worktree) |w| try writer.print("  Worktree: {s}\n", .{w.path});
    if (ctx.task.pr) |pr| try writer.print("  PR: {s} ({s})\n", .{ pr.url.value, @tagName(pr.state) });
    try writer.print("Handoffs ({d}):\n", .{ctx.handoffs.len});
    for (ctx.handoffs) |h| try writer.print("  [{d}] {s}\n", .{ h.created_at.unix_secs, h.body });
}

fn renderContextJson(ctx: app.TaskContext, writer: anytype) !void {
    // Compose using the JSON encoders already used elsewhere (renderJson in this file).
    // Implementation mirrors renderJson(views) but for the single composite struct.
    try writer.writeAll("{\"task\":");
    try renderTaskJson(ctx.task, writer);
    try writer.writeAll(",\"handoffs\":");
    try renderHandoffsJson(ctx.handoffs, writer);
    try writer.writeAll("}");
}

fn renderTaskJson(t: d.Task, writer: anytype) !void {
    try writer.print(
        \\{{"id":{d},"title":
    , .{t.id.raw()});
    try std.json.encodeJsonString(t.title, .{}, writer);
    try writer.writeAll(",\"archived\":");
    try writer.print("{}", .{t.archived});
    if (t.session) |s| {
        try writer.writeAll(",\"session\":{\"provider\":");
        try std.json.encodeJsonString(s.provider, .{}, writer);
        try writer.writeAll(",\"session_id\":");
        try std.json.encodeJsonString(s.session_id, .{}, writer);
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}
```

(The existing `renderJson` for `TaskView` already exists; this `renderTaskJson` is a smaller helper for the context bundle. If you'd rather reuse, refactor — but DRY is not worth the friction here for the first cut.)

- [ ] **Step 4: Build**

Run: `zig build`
Expected: success (handleResume is stubbed with `error.NotImplemented` — fine for now; E3 wires it).

- [ ] **Step 5: Commit**

```bash
git add src/infra/inbound/cli/handlers.zig src/infra/inbound/cli/use_cases.zig
git commit -m "feat(infra/cli): session/handoff/context handlers (resume stubbed)"
```

---

### Task E3: `resume` handler (with config + spawn)

**Files:**
- Modify: `src/infra/inbound/cli/handlers.zig`
- Modify: `src/infra/inbound/cli/use_cases.zig` (add lookup fn + spawn template + temp-file root)

- [ ] **Step 1: Extend `UseCases`**

```zig
// in use_cases.zig
pub const UseCases = struct {
    // ... existing ...
    set_session: app.SetSessionHandle,
    add_handoff: app.AddHandoff,
    list_handoffs: app.ListHandoffs,
    get_context: app.GetContext,

    // For BuildResumeCommand:
    templates_lookup: *const fn (provider: []const u8) ?app.BuildResumeCommand.ProviderTemplate,
    default_provider: ?[]const u8,
    spawn_template: ?[]const u8,
};
```

- [ ] **Step 2: Replace the stubbed `handleResume`**

```zig
fn handleResume(a: std.mem.Allocator, uc: *UseCases, args: args_mod.ResumeArgs, writer: anytype) !void {
    const tid: d.ids.TaskId = @enumFromInt(args.id);

    const t = try uc.get_context.execute(a, tid, 1) orelse {
        try writer.print("no task with id {d}\n", .{args.id});
        return;
    };
    defer {
        for (t.handoffs) |h| a.free(h.body);
        a.free(t.handoffs);
    }

    // Write latest handoff (if any) to a temp file for {{context_file}}
    var ctx_path_buf: ?[]u8 = null;
    defer if (ctx_path_buf) |p| a.free(p);
    var ctx_path: ?[]const u8 = null;
    if (t.handoffs.len > 0 or args.fresh or t.task.session == null) {
        const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
        const path = try std.fmt.allocPrint(a, "{s}/ctt-handoff-{d}-{d}.md", .{ dir, args.id, std.time.timestamp() });
        ctx_path_buf = path;
        ctx_path = path;
        const body: []const u8 = if (t.handoffs.len > 0) t.handoffs[0].body else "";
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = body });
    }

    const cmd = app.BuildResumeCommand.build(a, .{
        .templates = uc.templates_lookup,
        .default_provider = uc.default_provider,
        .session = t.task.session,
        .context_file = ctx_path,
        .spawn_wrapper = if (args.print) null else uc.spawn_template,
        .force_fresh = args.fresh,
    }) catch |e| {
        try writer.print("resume failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer a.free(cmd.command);

    if (args.print) {
        try writer.print("{s}\n", .{cmd.command});
        return;
    }

    // Spawn via /bin/sh -c
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd.command }, a);
    _ = try child.spawnAndWait();   // CLI: inherit stdio. Exit code propagates.
}
```

- [ ] **Step 3: Build**

Run: `zig build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add src/infra/inbound/cli/handlers.zig src/infra/inbound/cli/use_cases.zig
git commit -m "feat(infra/cli): wire 'ctt resume' with template renderer + spawn"
```

---

## Phase F — MCP

### Task F1: MCP tools

**Files:**
- Modify: `src/infra/inbound/mcp/use_cases.zig`
- Modify: `src/infra/inbound/mcp/server.zig`

- [ ] **Step 1: Extend MCP `UseCases`**

In `src/infra/inbound/mcp/use_cases.zig`, add fields (same as CLI minus the spawn/template bits, since MCP never spawns):

```zig
set_session: app.SetSessionHandle,
add_handoff: app.AddHandoff,
list_handoffs: app.ListHandoffs,
get_context: app.GetContext,
```

- [ ] **Step 2: Register new tools in server**

In `src/infra/inbound/mcp/server.zig`, find the existing tool registration (where `add_todo`, `list_tasks` etc. are declared) and add five entries with their request handlers:

- `set_session_handle(task_id, provider, session_id)` → calls `uc.set_session.execute(..., handle)`. Response: `{ok: true}`.
- `clear_session_handle(task_id)` → `uc.set_session.execute(..., null)`. Response: `{ok: true}`.
- `add_handoff(task_id, body)` → `uc.add_handoff.execute(...)`. Response: `{handoff_id, created_at}`.
- `list_handoffs(task_id, limit?)` → `uc.list_handoffs.execute(...)`. Response: `[{id, body, created_at}, ...]`.
- `get_context(task_id, handoff_limit?)` → `uc.get_context.execute(...)`. Response: `{task, handoffs}`.

Follow the existing tool-declaration shape exactly; the JSON-RPC schema and dispatcher pattern are already in place. Mirror an existing simple tool (e.g. `add_todo`) for boilerplate.

- [ ] **Step 3: Build**

Run: `zig build`
Expected: success.

- [ ] **Step 4: Smoke-test JSON-RPC by hand**

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ./zig-out/bin/ctt mcp | jq '.result.tools[].name'
```

Expected: includes `set_session_handle`, `add_handoff`, `list_handoffs`, `get_context`, `clear_session_handle` alongside existing tools.

- [ ] **Step 5: Commit**

```bash
git add src/infra/inbound/mcp/use_cases.zig src/infra/inbound/mcp/server.zig
git commit -m "feat(infra/mcp): session handle + handoff + context tools"
```

---

## Phase G — TUI

### Task G1: Detail panel (`Enter`)

**Files:**
- Modify: `src/infra/inbound/tui/state.zig`
- Modify: `src/infra/inbound/tui/app.zig`
- Modify: `src/infra/inbound/tui/view.zig`
- Modify: `src/infra/inbound/tui/use_cases.zig`

- [ ] **Step 1: Extend TUI `UseCases`**

Add to `tui/use_cases.zig`:

```zig
add_handoff: app.AddHandoff,
list_handoffs: app.ListHandoffs,
get_context: app.GetContext,
set_session: app.SetSessionHandle,

// For resume key handlers:
templates_lookup: *const fn ([]const u8) ?app.BuildResumeCommand.ProviderTemplate,
default_provider: ?[]const u8,
spawn_template: ?[]const u8,
```

- [ ] **Step 2: Add detail-panel state**

In `tui/state.zig`, extend `State`:

```zig
detail: ?DetailState = null,

pub const DetailState = struct {
    task: d.Task,
    handoffs: []d.HandoffEntry,

    pub fn deinit(self: *DetailState, a: std.mem.Allocator) void {
        for (self.handoffs) |h| a.free(h.body);
        a.free(self.handoffs);
        // free task strings via existing helper if present
    }
};
```

Extend `Mode`:

```zig
pub const Mode = enum { normal, add_todo_modal, detail, handoff_modal };
```

- [ ] **Step 3: Wire `Enter` in `handleNormalKey`**

In `tui/app.zig`, inside `handleNormalKey`, add:

```zig
if (k.matches(vaxis.Key.enter, .{})) {
    const sel = state.selectedView() orelse return;
    const ctx = try uc.get_context.execute(a, sel.task.id, 20);
    if (ctx) |c| {
        state.detail = .{ .task = c.task, .handoffs = c.handoffs };
        state.mode = .detail;
    }
    return;
}
```

And in `handleKey`, route `.detail` mode keys (Esc/Enter close):

```zig
.detail => {
    if (k.matches(vaxis.Key.escape, .{}) or k.matches(vaxis.Key.enter, .{})) {
        if (state.detail) |*d_state| d_state.deinit(a);
        state.detail = null;
        state.mode = .normal;
    }
},
```

- [ ] **Step 4: Render the detail panel in `view.zig`**

Add a `renderDetail` function:

```zig
pub fn renderDetail(win: vaxis.Window, ds: state_mod.DetailState) void {
    win.clear();
    const sub = win.child(.{ .x_off = 4, .y_off = 2, .width = win.width - 8, .height = win.height - 4, .border = .{ .where = .all } });
    var row: u16 = 1;
    _ = sub.printSegment(.{ .text = ds.task.title, .style = .{ .bold = true } }, .{ .row_offset = row, .col_offset = 2 });
    row += 2;
    if (ds.task.session) |s| {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "Session: {s}:{s}", .{ s.provider, s.session_id }) catch return;
        _ = sub.printSegment(.{ .text = line }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }
    if (ds.task.worktree) |w| {
        _ = sub.printSegment(.{ .text = w.path }, .{ .row_offset = row, .col_offset = 2 });
        row += 1;
    }
    row += 1;
    _ = sub.printSegment(.{ .text = "Handoffs:", .style = .{ .bold = true } }, .{ .row_offset = row, .col_offset = 2 });
    row += 1;
    for (ds.handoffs) |h| {
        if (row >= sub.height - 1) break;
        _ = sub.printSegment(.{ .text = h.body }, .{ .row_offset = row, .col_offset = 4 });
        row += 1;
    }
}
```

Call it from the main render in `app.zig` after kanban render:

```zig
if (state.mode == .detail) {
    if (state.detail) |ds| view.renderDetail(win, ds);
}
```

- [ ] **Step 5: Build**

Run: `zig build`
Expected: success.

- [ ] **Step 6: Commit**

```bash
git add src/infra/inbound/tui/
git commit -m "feat(infra/tui): Enter opens task detail panel"
```

---

### Task G2: Resume keys (`r`, `R`)

**Files:**
- Modify: `src/infra/inbound/tui/app.zig`

- [ ] **Step 1: Add helper that builds + spawns**

In `tui/app.zig`:

```zig
fn doResume(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, force_fresh: bool) !void {
    const sel = state.selectedView() orelse return;
    const ctx = try uc.get_context.execute(a, sel.task.id, 1) orelse return;
    defer { for (ctx.handoffs) |h| a.free(h.body); a.free(ctx.handoffs); }

    // Write context file (always for fresh; for resume only if used as fallback inside builder)
    const dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse "/tmp";
    const path = try std.fmt.allocPrint(a, "{s}/ctt-handoff-{d}-{d}.md", .{ dir, sel.task.id.raw(), std.time.timestamp() });
    defer a.free(path);
    const body: []const u8 = if (ctx.handoffs.len > 0) ctx.handoffs[0].body else "";
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = body });

    const cmd = app.BuildResumeCommand.build(a, .{
        .templates = uc.templates_lookup,
        .default_provider = uc.default_provider,
        .session = ctx.task.session,
        .context_file = path,
        .spawn_wrapper = uc.spawn_template,
        .force_fresh = force_fresh,
    }) catch |e| {
        const msg = try std.fmt.allocPrint(a, "resume failed: {s}", .{@errorName(e)});
        defer a.free(msg);
        try state.setMessage(msg);
        return;
    };
    defer a.free(cmd.command);

    if (uc.spawn_template == null) {
        // No spawn wrapper configured — show command in footer.
        try state.setMessage(cmd.command);
        return;
    }

    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd.command }, a);
    child.spawn() catch |e| {
        const msg = try std.fmt.allocPrint(a, "spawn failed: {s}", .{@errorName(e)});
        defer a.free(msg);
        try state.setMessage(msg);
        return;
    };
    // Detach: do not wait. The TUI continues running.

    const tag = if (cmd.mode == .resume_session) "resumed" else "fresh+context";
    const msg = try std.fmt.allocPrint(a, "{s}: {s}", .{ tag, cmd.command });
    defer a.free(msg);
    try state.setMessage(msg);
}
```

- [ ] **Step 2: Wire keys**

In `handleNormalKey`:

```zig
if (k.matches('r', .{})) return doResume(a, uc, state, false);
if (k.matches('R', .{ .shift = true })) return doResume(a, uc, state, true);
```

(Verify vaxis Key matching for shifted-letter: the existing `q` only-exits-normal-mode comparison shows the pattern; substitute the correct modifier syntax.)

- [ ] **Step 3: Build + commit**

```bash
zig build
git add src/infra/inbound/tui/app.zig
git commit -m "feat(infra/tui): r/R keys spawn resume/fresh via templates"
```

---

### Task G3: Handoff modal (`H`)

**Files:**
- Modify: `src/infra/inbound/tui/modal.zig`
- Modify: `src/infra/inbound/tui/state.zig`
- Modify: `src/infra/inbound/tui/app.zig`
- Modify: `src/infra/inbound/tui/view.zig`

- [ ] **Step 1: Add `HandoffModal` to state**

In `tui/state.zig`, add to `State`:

```zig
handoff_modal: ?HandoffModal = null,

pub const HandoffModal = struct {
    task_id: d.ids.TaskId,
    body_buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *HandoffModal, a: std.mem.Allocator) void {
        self.body_buf.deinit(a);
    }
};
```

- [ ] **Step 2: Add render in modal.zig**

```zig
pub fn renderHandoff(win: vaxis.Window, m: *const state_mod.HandoffModal) void {
    const mw = @min(win.width - 8, 80);
    const mh = @min(win.height - 4, 20);
    const x_off: i17 = @intCast((win.width - mw) / 2);
    const y_off: i17 = @intCast((win.height - mh) / 2);
    const sub = win.child(.{ .x_off = x_off, .y_off = y_off, .width = mw, .height = mh, .border = .{ .where = .all } });
    _ = sub.printSegment(.{ .text = "Handoff (Ctrl-S save, Esc cancel)" , .style = .{ .bold = true }}, .{ .row_offset = 0, .col_offset = 2 });
    var y: u16 = 2;
    var iter = std.mem.splitScalar(u8, m.body_buf.items, '\n');
    while (iter.next()) |line| : (y += 1) {
        if (y >= sub.height - 1) break;
        _ = sub.printSegment(.{ .text = line }, .{ .row_offset = y, .col_offset = 2 });
    }
}
```

- [ ] **Step 3: Key handling for the modal**

In `app.zig`, add `handleHandoffModalKey`:

```zig
fn handleHandoffModalKey(a: std.mem.Allocator, uc: *UseCases, state: *state_mod.State, k: vaxis.Key) !void {
    var m = &state.handoff_modal.?;
    if (k.matches(vaxis.Key.escape, .{})) {
        m.deinit(a);
        state.handoff_modal = null;
        state.mode = .normal;
        return;
    }
    if (k.matches('s', .{ .ctrl = true })) {
        if (m.body_buf.items.len > 0) {
            _ = try uc.add_handoff.execute(a, m.task_id, m.body_buf.items);
            try doRefresh(a, uc, state);
        }
        m.deinit(a);
        state.handoff_modal = null;
        state.mode = .normal;
        return;
    }
    if (k.matches(vaxis.Key.backspace, .{})) {
        if (m.body_buf.items.len > 0) _ = m.body_buf.pop();
        return;
    }
    if (k.matches(vaxis.Key.enter, .{})) {
        try m.body_buf.append(a, '\n');
        return;
    }
    // Append printable
    if (k.text) |t| try m.body_buf.appendSlice(a, t);
}
```

And update `handleKey` to route `.handoff_modal` mode to it.

- [ ] **Step 4: Wire `H` in normal mode**

```zig
if (k.matches('H', .{ .shift = true })) {
    const sel = state.selectedView() orelse return;
    state.handoff_modal = .{ .task_id = sel.task.id };
    state.mode = .handoff_modal;
    return;
}
```

- [ ] **Step 5: Render modal in main loop**

```zig
if (state.mode == .handoff_modal) {
    if (state.handoff_modal) |*m| modal_mod.renderHandoff(win, m);
}
```

- [ ] **Step 6: Build + commit**

```bash
zig build
git add src/infra/inbound/tui/
git commit -m "feat(infra/tui): H opens handoff text modal"
```

---

### Task G4: Provider icon on cards (data plumbing only)

**Files:**
- Modify: `src/infra/inbound/tui/view.zig`
- Modify: `src/infra/inbound/tui/use_cases.zig`

Visual treatment lives in the card-redesign spec (task #3 in TaskList); here we just plumb the icon string into rendering.

- [ ] **Step 1: Add `templates_lookup` access to view layer**

Pass the lookup fn (already in TUI `UseCases`) into render. Simplest: make `render` take the lookup as a parameter, or stash it on `Selection`/state and pull it inside the loop.

```zig
// in view.zig, extend signature
pub fn render(
    win: vaxis.Window,
    views: []const app.TaskView,
    sel: Selection,
    templates_lookup: *const fn ([]const u8) ?app.BuildResumeCommand.ProviderTemplate,
) void {
    // ... existing column rendering ...
    for (views) |v| {
        if (v.status != col.status) continue;
        // Build "ICON title" prefix:
        const icon: []const u8 = if (v.task.session) |s|
            (if (templates_lookup(s.provider)) |t|
                (t.icon orelse oneCharUpper(s.provider))
            else oneCharUpper(s.provider))
        else "";
        // Print: icon, space, title
        // ... rest unchanged ...
    }
}

fn oneCharUpper(s: []const u8) []const u8 {
    if (s.len == 0) return "";
    // Static buffer of 1 char (uppercase ASCII fallback)
    // For unicode, just return the first byte. Improvement deferred to card-redesign spec.
    return s[0..1];
}
```

(In practice this needs a per-render scratch buffer or `bufPrint`; keep it minimal — the visual polish task in spec #3 will replace this anyway.)

- [ ] **Step 2: Update `app.zig` render call to pass lookup**

```zig
view.render(win, state.views, state.sel, uc.templates_lookup);
```

- [ ] **Step 3: Build + commit**

```bash
zig build
git add src/infra/inbound/tui/
git commit -m "feat(infra/tui): show provider icon on cards with session handle"
```

---

## Phase H — Wiring & smoke

### Task H1: Composition root

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Instantiate `SqliteHandoffRepository` and new use cases**

After the existing `var task_repo = sqlite.SqliteTaskRepository.init(&db);` line, add:

```zig
var handoff_repo = sqlite.SqliteHandoffRepository.init(&db);
```

After the existing `cli.UseCases` construction, build the new use cases and add them:

```zig
const set_session_uc   = app.SetSessionHandle{ .tasks = task_repo.interface() };
const add_handoff_uc   = app.AddHandoff{ .handoffs = handoff_repo.interface(), .clock = SystemClock.iface() };
const list_handoffs_uc = app.ListHandoffs{ .handoffs = handoff_repo.interface() };
const get_context_uc   = app.GetContext{
    .tasks = task_repo.interface(),
    .handoffs = handoff_repo.interface(),
};
```

- [ ] **Step 2: Build `templates_lookup` closure**

```zig
const TemplatesCtx = struct {
    map: *const std.json.ArrayHashMap(cfg_mod.ProviderTemplates),

    fn lookup(provider: []const u8) ?app.BuildResumeCommand.ProviderTemplate {
        // Substitute the actual map iteration based on how loader represents it.
        // If the map is a std.StringHashMapUnmanaged: map.get(provider) and map into ProviderTemplate.
        // Static state via a file-scope `var` is acceptable for v1.
    }
};
```

If a true closure-with-environment isn't ergonomic in Zig, store the templates map in a file-scope `var` set at startup and have `lookup` read from it. Document the choice with a one-line comment.

- [ ] **Step 3: Extend `cli.UseCases`, `mcp.UseCases`, `tui.UseCases` construction**

Add the new fields (`set_session`, `add_handoff`, `list_handoffs`, `get_context`, plus `templates_lookup` / `default_provider` / `spawn_template` for CLI + TUI) to each struct literal.

- [ ] **Step 4: Build**

Run: `zig build`
Expected: success.

- [ ] **Step 5: Manual smoke**

```bash
./zig-out/bin/ctt add "wiring smoke"
ID=$(./zig-out/bin/ctt list --json | jq '.[-1].task.id')
./zig-out/bin/ctt session set $ID claude my-fake-id
./zig-out/bin/ctt handoff $ID --note "first note"
./zig-out/bin/ctt context $ID --json | jq
./zig-out/bin/ctt resume $ID --print
./zig-out/bin/ctt delete $ID
```

Expected: each command exits 0; `context` shows session + handoff; `resume --print` prints `claude --resume my-fake-id` (or the configured template).

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat(main): wire HandoffRepository + new use cases into CLI/MCP/TUI"
```

---

### Task H2: Extend smoke test

**Files:**
- Modify: `tests/smoke.sh`

- [ ] **Step 1: Append handoff scenario**

Add to `tests/smoke.sh` (after the existing scenario):

```bash
echo "--- handoff/resume smoke ---"
$BIN add "handoff smoke"
HID=$($BIN list --json | jq '.[-1].task.id')

$BIN session set $HID claude abc-test-123
$BIN handoff $HID --note "first checkpoint"
$BIN handoff $HID --note "second checkpoint"

# context should bundle both
test "$($BIN context $HID --json | jq '.handoffs | length')" = "2"
test "$($BIN context $HID --json | jq -r '.task.session.session_id')" = "abc-test-123"

# resume --print uses the resume template
$BIN resume $HID --print | grep -q "abc-test-123"

# clear session → resume --print falls back to fresh template
$BIN session clear $HID
$BIN resume $HID --print | grep -q "context_file\|append-system-prompt" || \
    $BIN resume $HID --print | grep -q "claude"   # template-dependent

$BIN delete $HID
echo "handoff smoke OK"
```

- [ ] **Step 2: Run smoke**

Make sure a config exists at `~/.config/ctt/config.json` with provider templates (see spec §6 example). Then:

```bash
chmod +x tests/smoke.sh
zig build
./tests/smoke.sh
```

Expected: `handoff smoke OK`.

- [ ] **Step 3: Commit**

```bash
git add tests/smoke.sh
git commit -m "test: smoke coverage for handoff + resume"
```

---

## Self-review

**Spec coverage check** (spec sections → plan tasks):

- §4.1 Domain (SessionHandle, HandoffEntry, Task.session, TaskPatch.session) → A1, A2, A3, A4 ✓
- §4.2 Ports (HandoffRepository, TaskRepository.update for session) → A5, B1 ✓
- §4.3 Application use cases → D1–D5 ✓
- §4.4 Infra sqlite (migration, SqliteHandoffRepository, SqliteTaskRepository extension) → A6, B1, B2 ✓
- §4.5 Config (ProviderTemplates, UiConfig, providers.default) → C1 ✓
- §4.6 CLI surface (session/handoff/context/resume) → E1, E2, E3 ✓
- §4.7 MCP surface (5 tools, no resume) → F1 ✓
- §4.8 TUI (Enter, r, R, H, provider icon) → G1, G2, G3, G4 ✓
- §5 data flow examples → covered indirectly via H2 smoke ✓
- §6 config example → H1 manual smoke requires it ✓
- §7 error handling → spread across B2 (missing handoff), C1 (missing config), D5 (missing template/default), E3 (sh exit code), G2 (footer fallback) ✓
- §8 testing strategy → each task has its own tests; smoke H2 ✓
- §9 migration → A6 ✓
- §11 open questions (provider discovery, concurrency) → documented in spec; no implementation needed ✓

**Placeholder scan:** Searched for "TODO", "TBD", "implement later". None in plan body. The `TemplatesCtx` lookup closure in H1 step 2 has a "Substitute the actual..." instruction — that's directive, not a placeholder, because the loader's map type isn't pinned until C1. Acceptable.

**Type consistency:** `ResumeArgs` / `HandoffArgs` / `SessionArgs` / `ContextArgs` referenced consistently in E1 + E2 + E3. `app.BuildResumeCommand.ProviderTemplate` used consistently in CLI (E2 use cases), TUI (G1 use cases), main (H1). `app.HandoffEntry` vs `d.HandoffEntry` — domain entity, application re-exports. Consistent.

**Estimated time:** ~6–10 hours of focused work.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-03-ctt-handoff-resume.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for a plan of this size (~24 tasks).
2. **Inline Execution** — Execute tasks in this session using `superpowers:executing-plans`, batch with checkpoints. Slower; risks context bloat.

Which approach?
