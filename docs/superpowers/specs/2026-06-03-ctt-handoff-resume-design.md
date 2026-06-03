# ctt — Per-task Handoff & Resume (Design)

**Date:** 2026-06-03
**Status:** Approved design, not yet implemented
**Builds on:** `2026-06-02-ctt-claude-task-tracker-design.md`

## 1. Overview

Each ctt task gains two new pieces of state:

- A **session handle** — an optional `(provider, session_id)` pair pointing at the live LLM session most recently associated with the task.
- A **handoff log** — an append-only series of free-form markdown entries written by whoever is putting the task down, so the next person (human or LLM) picking it up has enough context to continue without re-deriving anything.

These cover two distinct resume flows:

- **Cold start:** user has the kanban TUI open, hits `<r>` on a task → ctt spawns a new terminal running e.g. `claude --resume <session_id>`. The prior session boots with full tool history intact.
- **Warm continue:** user is already inside an LLM session, asks "what's on my plate?" → the LLM calls `list_tasks`, the user picks one, the LLM calls `get_context` to absorb the handoff log and starts working in the *current* session. No spawning. When the session ends, the LLM writes a new handoff and updates the session handle to point at itself.

Both flows are provider-agnostic at the schema level: provider names and resume/fresh command templates live in user config, never in ctt source.

## 2. Goals

- Make any task resumable from a cold start in a new terminal via one keypress.
- Make any task picked-uppable from inside an existing LLM session via one MCP/CLI call that returns everything needed.
- Stay LLM-provider-agnostic: no hardcoded "claude" / "codex" / "cursor" anywhere in ctt source. New provider = new entry in `providers.templates` in config.
- Keep the LLM as the one who writes handoffs (it knows what mattered); ctt is a dumb store.
- Preserve the existing hexagonal layout: new domain entities, ports, and adapters; no leakage of infra concerns into domain.

## 3. Non-goals (v1)

- No auto-detection of session ids by ctt. Whoever calls `set_session_handle` provides the id. (Detection conventions per provider documented in §11.)
- No "is this session still alive?" probe. If `claude --resume <id>` fails, the user falls back to `<R>` (fresh + handoff) manually.
- No multi-handle per task. One handle slot; a new `set_session_handle` overwrites the previous.
- No handoff retention, pruning, or size cap.
- No web UI / notifications / daemon. Same posture as v1.

## 4. Architecture

### 4.1 Domain (new)

**Value objects** — `src/domain/value_objects/session_handle.zig`:

```zig
pub const SessionHandle = struct {
    provider: []const u8,    // e.g. "claude", "codex"
    session_id: []const u8,  // opaque to ctt
};
```

**Entity** — `src/domain/entities/handoff.zig`:

```zig
pub const HandoffEntry = struct {
    id: ids.HandoffId,
    task_id: ids.TaskId,
    body: []const u8,           // markdown, no size cap
    created_at: Timestamp,
};

pub const NewHandoff = struct {
    task_id: ids.TaskId,
    body: []const u8,
};
```

**Task changes** — `src/domain/entities/task.zig`:

```zig
pub const Task = struct {
    // ... existing fields ...
    session: ?SessionHandle,    // NEW
};

pub const TaskPatch = struct {
    // ... existing fields ...
    session: ??SessionHandle,   // ??: outer null = no change, Some(null) = clear, Some(x) = set
};
```

`derive_status` is unchanged — neither handle nor handoff log affects status.

### 4.2 Ports

**Extended** — `src/domain/ports/task_repository.zig`:

```zig
pub const TaskRepository = struct {
    // ... existing methods ...
    setSessionHandle: *const fn (self, TaskId, ?SessionHandle) anyerror!void,
};
```

(Alternative: roll into existing `update` via `TaskPatch.session`. Implementation choice; spec allows either.)

**New** — `src/domain/ports/handoff_repository.zig`:

```zig
pub const HandoffRepository = struct {
    append: *const fn (self, NewHandoff, now: Timestamp) anyerror!HandoffId,
    list:   *const fn (self, TaskId, limit: ?u32) anyerror![]HandoffEntry,
    latest: *const fn (self, TaskId) anyerror!?HandoffEntry,
};
```

### 4.3 Application (use cases)

New files under `src/application/use_cases/`:

- `set_session_handle.zig` — `execute(task_id, ?SessionHandle)`.
- `add_handoff.zig` — `execute(task_id, body) → HandoffId`. Uses `Clock` port for `now`.
- `list_handoffs.zig` — `execute(task_id, limit?) → []HandoffEntry`.
- `get_context.zig` — `execute(task_id, handoff_limit?)` returns a composite struct:
  ```zig
  pub const TaskContext = struct {
      task: d.Task,           // includes session handle
      worktree: ?Worktree,    // already on task; surfaced for convenience
      pr: ?Pr,
      issue: ?Issue,
      handoffs: []HandoffEntry,
  };
  ```
- `build_resume_command.zig` — pure template-renderer. Inputs: `provider`, `templates: ProviderTemplates`, `session_id: ?[]const u8`, `context_file: ?[]const u8`. Output: `ResumeCommand { command: []const u8, mode: enum { resume, fresh } }`. This is the bit with non-trivial logic and gets the most tests.

### 4.4 Infra — outbound (SQLite)

`src/infra/outbound/sqlite/` gets:

- A `SqliteHandoffRepository` (mirroring `SqliteTaskRepository`).
- A migration step that runs on `Db.open`. Idempotent:

```sql
-- migration 2: handoff & session handle
ALTER TABLE tasks ADD COLUMN session_provider TEXT;
ALTER TABLE tasks ADD COLUMN session_id TEXT;

CREATE TABLE IF NOT EXISTS handoffs (
  id INTEGER PRIMARY KEY,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  body TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS handoffs_task_created
  ON handoffs(task_id, created_at DESC);
```

Migration runner tracks a `schema_version` row in a `meta` table (or `PRAGMA user_version` if simpler). `ALTER TABLE ... ADD COLUMN` is not idempotent in SQLite, so the runner gates it on the version.

### 4.5 Infra — outbound (config)

`src/infra/outbound/config/loader.zig` grows:

```zig
pub const ProviderTemplates = struct {
    resume: ?[]const u8 = null,
    fresh:  ?[]const u8 = null,
    icon:   ?[]const u8 = null,   // short string (emoji or 1-3 chars) shown on the TUI card
};

pub const UiConfig = struct {
    spawn: ?[]const u8 = null,   // null = no spawn, print-to-footer fallback
};

pub const ProvidersConfig = struct {
    // ... existing ...
    templates: std.StringHashMapUnmanaged(ProviderTemplates) = .{},  // keyed by provider name
};

pub const Config = struct {
    // ... existing ...
    ui: UiConfig = .{},
};
```

JSON deserialisation: `providers.templates` is a JSON object whose keys are provider names. Use `std.json.ObjectMap` or a custom parser.

Placeholders are pure string substitution (`std.mem.replaceOwned`); no Mustache, no shell parsing in ctt:

- `{{session_id}}` — replaced in `resume` template
- `{{context_file}}` — replaced in `fresh` template (path to a temp file containing the latest handoff body, or empty)
- `{{cmd}}` — replaced in `ui.spawn` with the rendered inner command

Quoting/escaping is the shell's problem; ctt passes the final string to `/bin/sh -c`.

### 4.6 Infra — inbound (CLI)

New subcommands (`src/infra/inbound/cli/args.zig`):

```
ctt session set <task-id> <provider> <session-id>
ctt session clear <task-id>

ctt handoff <task-id> --note "single-line summary"   # short
ctt handoff <task-id>                                 # multi-line from stdin
ctt handoff <task-id> --list [--json]                 # show past entries
ctt handoff <task-id> --latest [--json]               # just the most recent

ctt context <task-id> [--json] [--handoffs N]         # bundled get_context

ctt resume <task-id>                                  # spawn via ui.spawn (default)
ctt resume <task-id> --print                          # print rendered command + handoff, no spawn
ctt resume <task-id> --fresh                          # force fresh+context even if handle present
```

`ctt resume` semantics:

1. Load task.
2. If `--fresh` or no session handle: pick fresh template for the provider named by `task.session.provider` if set, else `providers.default`, else the only template key if exactly one exists, else error.
3. Otherwise: pick resume template for `task.session.provider` and render with `task.session.session_id`.
4. If template path is "fresh", write latest handoff body to a temp file (`$XDG_RUNTIME_DIR/ctt-handoff-<task>-<unix_ts>.md`, falling back to `/tmp`) and substitute `{{context_file}}`. If no handoff exists, the file is created empty.
5. If `ui.spawn` is set, wrap rendered command with it; exec via `/bin/sh -c`.
6. If `ui.spawn` is unset and command was invoked via `--print`, print rendered command. If `ui.spawn` is unset and command was invoked without `--print`, exec inline (CLI; user is at a shell anyway).

### 4.7 Infra — inbound (MCP)

New tools (`src/infra/inbound/mcp/server.zig`):

- `set_session_handle(task_id, provider, session_id)` → ok
- `clear_session_handle(task_id)` → ok
- `add_handoff(task_id, body)` → `{handoff_id, created_at}`
- `list_handoffs(task_id, limit?)` → `[{id, body, created_at}, ...]`
- `get_context(task_id, handoff_limit?)` → full `TaskContext` JSON

**No `resume` MCP tool.** Spawning terminal windows from an MCP server is the wrong layering; resume is a human/TUI/CLI action.

### 4.8 Infra — inbound (TUI)

Existing kanban view (`src/infra/inbound/tui/view.zig`) keeps four columns. New keys in `src/infra/inbound/tui/app.zig`:

| Key | Action |
|---|---|
| `Enter` | Expand selected task → detail panel showing task fields + branch + worktree + PR + issue + session handle + last N handoff entries. Same data as `get_context`. `Esc` or `Enter` again to collapse. |
| `r` | Resume selected: if session handle present → render `providers.templates.<provider>.resume` and spawn via `ui.spawn`; else fall through to fresh+context (same as `R`). |
| `R` | Force fresh+context: render `providers.templates.<provider>.fresh` with latest handoff written to temp file, spawn via `ui.spawn`. |
| `H` | Open handoff modal — multi-line text area, `Ctrl-S` saves a new entry, `Esc` cancels. After save, the TUI calls existing `doRefresh` so the detail view reflects the new entry. |

Existing keys preserved: `h`/`l` cross columns, `j`/`k` within column. All current actions (add, archive, delete, refresh) unchanged.

**Provider icon on cards.** When a task has a session handle, the card shows the provider icon (`providers.templates.<provider>.icon`) next to the title. If the provider has no icon configured, fall back to the first character of the provider name uppercased. If the task has no session handle, no icon. The detail panel (`Enter`) shows the full `provider:session_id` regardless. Card layout details (padding, border per task, icon placement) are owned by the TUI card-redesign spec; this spec only specifies the data and the fallback rule.

When `ui.spawn` is null and the user hits `r`/`R`: footer prints the rendered inner command and a hint ("no ui.spawn configured; run the above in a shell"). The TUI stays foregrounded. Spawn exit codes are not observable from the TUI because the spawn is fire-and-forget once dispatched.

## 5. Data flow examples

### 5.1 Cold start — user hits `<r>` in TUI

```
TUI: keyHandler('r')
  → app.UseCases.build_resume_command(task, cfg.providers.templates, cfg.ui)
       → ResumeCommand{ command: "tmux new-window -- claude --resume abc123", mode: .resume }
  → posix.spawn("/bin/sh", ["-c", command])
  → footer: "spawned: claude resume abc123"
```

### 5.2 Warm continue — LLM picks a task

```
[in Claude session]
  user: "what's on my plate?"
  claude → MCP list_tasks() → shows tasks
  user: "let's do #7"
  claude → MCP get_context(7) → {task, branch, pr, issue, handoffs: [...]}
  claude reads handoff[0].body, internalises, says "picking up where you left off..."
  [work happens]
  claude → MCP add_handoff(7, "<new summary>")
  claude → MCP set_session_handle(7, "claude", "<my session id>")
```

### 5.3 Fresh fallback when session died

```
TUI: keyHandler('R')   # explicit fresh
  → write latest_handoff.body to /tmp/ctt-handoff-7-1717459200.md
  → BuildResumeCommand renders:
       fresh template:  claude --append-system-prompt "$(cat /tmp/ctt-handoff-7-...)"
       spawn template:  tmux new-window -- claude --append-system-prompt "$(cat ...)"
  → posix.spawn
```

## 6. Config example (full)

```jsonc
{
  "db_path": "/Users/me/.config/ctt/db.sqlite",
  "repos": [
    {"name": "ctt", "path": "/Users/me/tru4m/ctt", "github": "tru4m/ctt"}
  ],
  "providers": {
    "patterns": [{"provider": "linear", "prefix_min": 2, "prefix_max": 6}],
    "default": "claude",
    "templates": {
      "claude": {
        "resume": "claude --resume {{session_id}}",
        "fresh":  "claude --append-system-prompt \"$(cat {{context_file}})\"",
        "icon":   "C"
      },
      "codex": {
        "resume": "codex resume {{session_id}}",
        "fresh":  "codex",
        "icon":   "X"
      }
    }
  },
  "ui": {
    "spawn": "tmux new-window -- {{cmd}}"
  }
}
```

## 7. Error handling

| Condition | Behaviour |
|---|---|
| Provider template missing (`providers.templates.X` absent or `.resume`/`.fresh` null) | CLI: stderr + non-zero exit. TUI: footer message, no spawn. |
| `r` pressed, no session handle | Silent fallback to fresh+context path. Documented. |
| `R`/fresh pressed, no handoff entries | Spawn with empty temp file (i.e. `{{context_file}}` substituted with path to a 0-byte file). |
| SQLite migration fails | Error at `Db.open`; ctt refuses to start. User sees stack trace; no fallback. |
| Spawn command exits non-zero | CLI: bubble exit code. TUI: show exit code in footer; can't do more (spawn is detached after dispatch). |
| `ui.spawn` null + TUI `r`/`R` | Footer prints rendered inner command for copy/paste. |
| `ui.spawn` null + CLI `ctt resume` (no `--print`) | Exec inline (user is already at a shell). |

## 8. Testing strategy

Per existing hexagonal layout:

- **Domain:** value-object equality for `SessionHandle`; entity construction for `HandoffEntry`.
- **Application:** use-case tests with in-memory fakes.
  - `BuildResumeCommand` gets exhaustive coverage: each placeholder, missing template, missing session_id, escape-sensitive content.
- **Infra/sqlite:** repo CRUD; migration applies from scratch + from v1 schema; `ON DELETE CASCADE` removes handoffs when a task is deleted.
- **Infra/cli:** arg parsing for each new subcommand, including error cases (`UnknownCommand`, `MissingArg`).
- **Infra/tui:** keymap dispatch; modal lifecycle (open → type → Ctrl-S → close + refresh; open → Esc → cancel).
- **Infra/mcp:** request parsing + response shape for each new tool.

Smoke test (extend `tests/smoke.sh`):

```bash
ctt add "smoke handoff test"
ID=$(ctt list --json | jq '.[0].task.id')
ctt session set $ID claude abc-123
ctt handoff $ID --note "first checkpoint"
ctt handoff $ID --note "second checkpoint"
ctt context $ID --json | jq '.handoffs | length' | grep -q 2
ctt context $ID --json | jq -r '.task.session.session_id' | grep -q abc-123
ctt resume $ID --print | grep -q "claude --resume abc-123"
ctt session clear $ID
ctt resume $ID --print | grep -q "append-system-prompt"   # fell back to fresh
ctt delete $ID
[ "$(ctt context $ID --json 2>&1 | grep -c error)" -ge 1 ]   # cascade removed task
echo "handoff smoke OK"
```

## 9. Migration & rollout

- One implementation phase, gated on schema version 2.
- Existing v1 databases auto-migrate on first open of a new binary.
- Old binaries reading a v2 database will fail to query the new columns; this is acceptable (single-user tool, no rollback story needed).

## 10. Out of scope (parked for follow-ups)

These are real needs the user surfaced during this brainstorm; tracked separately:

- **TUI auto-refresh on external DB writes** — the kanban currently only reloads on key actions, so handoffs written by an external LLM session won't surface until you press `r`. Needs its own design (poll vs SQLite hook vs file watcher).
- **TUI card visual redesign** — current rendering puts each task as a wrapping line inside a column; should be a proper bordered card per task. Will land alongside the detail-panel work but is its own spec.
- **Handoff retention / pruning** — `ctt handoff <id> --prune --keep N` once handoff bloat becomes a real problem.

## 11. Open questions

1. **Session id discovery.** ctt never auto-detects; the caller of `set_session_handle` supplies the string. Known conventions, documented for the user:
   - **Claude Code:** session id is the UUID in the active transcript filename under `~/.claude/projects/<cwd-hash>/<uuid>.jsonl`. No canonical env var at the time of writing.
   - **Codex / Cursor / Gemini:** TBD; user fills in their own templates and discovery wrapper.
2. **Concurrent handoff writes.** Two LLMs writing to the same task simultaneously is benign; SQLite serialises and entries get distinct ids/timestamps. No app-level locking.
