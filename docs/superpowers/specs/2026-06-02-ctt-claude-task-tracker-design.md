# ctt — Claude Task Tracker (Design)

**Date:** 2026-06-02
**Status:** Approved design, not yet implemented
**Stack:** Zig 0.14.x, libvaxis, zqlite

## 1. Overview

`ctt` is a terminal tool for tracking Claude-assisted development work across multiple repositories. Each unit of work is a **Task**. Tasks are usually backed by a git worktree; some start life as standalone Todos before a worktree exists.

`ctt` exposes three surfaces over the same data:
- A Kanban-style TUI for the human
- A CLI with JSON output for scripts
- An MCP server so Claude can read and write the task list directly

## 2. Goals

- See every in-flight worktree across all configured repos in one place, grouped by status.
- Show whether a worktree has a PR yet, and if so the PR link and state.
- Capture standalone Todos before a worktree exists, and auto-link them when the worktree is created.
- Pull issue title/state from Linear when a branch name encodes a ticket id.
- Be scriptable by Claude (CLI + MCP) without depending on the TUI.

## 3. Non-goals (v1)

- No background daemon or live polling. Refresh on launch and on demand.
- No web UI, multi-user sync, or notifications.
- No write-back to Linear (read-only).
- No Jira / GitHub-Issues adapters (provider interface is ready; adapters not built).
- No OS keychain integration (env var + 0600 file in v1; keychain via `@cImport` in v1.1).

## 4. Architecture

Hexagonal (ports and adapters), enforced at compile time by `build.zig` module dependencies.

```
ctt/
├── build.zig                 # module graph; enforces hex deps
├── build.zig.zon             # dependency manifest (libvaxis, zqlite, …)
├── src/
│   ├── domain/               # pure, std-only
│   │   ├── root.zig
│   │   ├── entities/
│   │   ├── value_objects/
│   │   ├── ports/            # vtable interface structs
│   │   └── services/         # pure functions: status derivation, ticket parsing
│   ├── application/          # use cases; depends on domain only
│   │   └── use_cases/
│   ├── infra/
│   │   ├── inbound/          # driving adapters (call INTO the app)
│   │   │   ├── tui/          # libvaxis
│   │   │   ├── cli/          # zig-clap
│   │   │   └── mcp/          # JSON-RPC 2.0 over stdio
│   │   └── outbound/         # driven adapters (the app calls OUT to)
│   │       ├── sqlite/       # zqlite
│   │       ├── git/          # std.ChildProcess: `git worktree list --porcelain`
│   │       ├── gh/           # std.ChildProcess: `gh pr list ... --json ...`
│   │       └── linear/       # std.http.Client → Linear GraphQL
│   └── main.zig              # composition root — single `ctt` binary
└── tests/
```

### Dependency direction

```
infra/inbound/*  ──> application ──> domain
infra/outbound/* ───────────────────^
main.zig ──> everything (composition root only)
```

- `domain` and `application` never import from `infra/`.
- Inbound adapters drive use cases. Outbound adapters implement domain ports.
- `main.zig` is the only file that knows about zqlite, `gh`, Linear, libvaxis, or clap.

## 5. Data model

`Task` is the central entity. `Worktree`, `Pr`, and `Issue` are observed facts about the world that a `Task` points at. **Status is derived** from those links and never stored, so it cannot drift.

### Domain entities

```zig
pub const Task = struct {
    id: TaskId,
    title: []const u8,
    branch_hint: ?BranchName,
    worktree: ?Worktree,
    pr: ?Pr,
    issue: ?Issue,
    archived: bool,
    notes: ?[]const u8,
    created_at: Timestamp,
    updated_at: Timestamp,
};

pub const Worktree = struct {
    id: WorktreeId,
    repo: RepoRef,
    path: []const u8,
    branch: BranchName,
    head_sha: Sha,
    commits_ahead_of_default: u32,   // vs repo.default_branch
    has_upstream: bool,              // branch tracks a remote
    commits_ahead_of_upstream: ?u32, // null if !has_upstream
    last_seen_at: Timestamp,
};

pub const Pr = struct {
    id: PrId,
    repo: RepoRef,
    number: u32,
    url: []const u8,
    title: []const u8,
    head_branch: BranchName,
    state: PrState,           // open | draft | merged | closed
    updated_at: Timestamp,
    fetched_at: Timestamp,
};

pub const Issue = struct {
    id: IssueId,
    provider: ProviderId,     // "linear", "jira", …
    external_id: []const u8,  // "MOE-272"
    url: ?[]const u8,
    title: ?[]const u8,
    state: ?[]const u8,
    fetched_at: Timestamp,
};

pub const Status = enum { todo, in_progress, in_review, done, archived };
pub const PrState = enum { open, draft, merged, closed };
```

### Status derivation (pure, `domain/services/status.zig`)

```zig
pub fn derive(task: Task) Status {
    if (task.archived) return .archived;
    if (task.pr) |pr| return switch (pr.state) {
        .merged, .closed => .done,
        .open, .draft    => .in_review,
    };
    return if (task.worktree != null) .in_progress else .todo;
}
```

The "branch pushed, no PR yet" sub-state lives inside `in_progress`. The TUI surfaces it as a per-card hint and a key to create a PR.

### SQLite schema (`infra/outbound/sqlite/migrations/0001_init.sql`)

```sql
CREATE TABLE repos (
    id              INTEGER PRIMARY KEY,
    name            TEXT NOT NULL UNIQUE,
    root_path       TEXT NOT NULL UNIQUE,
    github          TEXT,                  -- "owner/repo" for gh
    default_branch  TEXT NOT NULL DEFAULT 'main'
);

CREATE TABLE worktrees (
    id                          INTEGER PRIMARY KEY,
    repo_id                     INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    path                        TEXT NOT NULL UNIQUE,
    branch                      TEXT NOT NULL,
    head_sha                    TEXT NOT NULL,
    commits_ahead_of_default    INTEGER NOT NULL DEFAULT 0,
    has_upstream                INTEGER NOT NULL DEFAULT 0,
    commits_ahead_of_upstream   INTEGER,
    last_seen_at                TEXT NOT NULL,
    UNIQUE (repo_id, branch)
);

CREATE TABLE prs (
    id              INTEGER PRIMARY KEY,
    repo_id         INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    number          INTEGER NOT NULL,
    url             TEXT NOT NULL,
    title           TEXT NOT NULL,
    head_branch     TEXT NOT NULL,
    state           TEXT NOT NULL CHECK (state IN ('open','draft','merged','closed')),
    updated_at      TEXT NOT NULL,
    fetched_at      TEXT NOT NULL,
    UNIQUE (repo_id, number)
);

CREATE TABLE issues (
    id              INTEGER PRIMARY KEY,
    provider        TEXT NOT NULL,
    external_id     TEXT NOT NULL,
    url             TEXT,
    title           TEXT,
    state           TEXT,
    fetched_at      TEXT NOT NULL,
    UNIQUE (provider, external_id)
);

CREATE TABLE tasks (
    id              INTEGER PRIMARY KEY,
    title           TEXT NOT NULL,
    branch_hint     TEXT,
    worktree_id     INTEGER REFERENCES worktrees(id) ON DELETE SET NULL,
    pr_id           INTEGER REFERENCES prs(id) ON DELETE SET NULL,
    issue_id        INTEGER REFERENCES issues(id) ON DELETE SET NULL,
    archived        INTEGER NOT NULL DEFAULT 0,
    notes           TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
```

### Linking rules

- **Discovery creates Tasks lazily.** A discovered worktree without a Task gets one auto-created with `title = branch name`. Every worktree always has a Task.
- **Manual Todos** are Tasks with `branch_hint` set and `worktree_id = NULL`.
- **Auto-link on refresh:** if a Task has `branch_hint = b` and a worktree on branch `b` is discovered, the worktree attaches to that existing Task instead of creating a new one.
- **PR link:** when a PR's `head_branch` matches a Task's worktree's branch, attach the PR.
- **Issue link:** parsed from the branch name (e.g., `moe-272-foo` → `MOE-272`), or set manually.

## 6. Ports & use cases

### Ports (`domain/ports/`)

Each port is a **vtable interface struct**:

```zig
// domain/ports/task_repository.zig
pub const TaskRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ NotFound, Conflict, Io };

    pub const VTable = struct {
        create: *const fn (*anyopaque, NewTask) Error!Task,
        get:    *const fn (*anyopaque, TaskId) Error!?Task,
        list:   *const fn (*anyopaque, TaskFilter) Error![]Task,
        update: *const fn (*anyopaque, TaskId, TaskPatch) Error!Task,
        delete: *const fn (*anyopaque, TaskId) Error!void,
    };

    pub fn create(self: TaskRepository, draft: NewTask) Error!Task {
        return self.vtable.create(self.ptr, draft);
    }
    // thin shims for the rest
};
```

Defined ports:

| Port | Implemented by | Purpose |
|---|---|---|
| `TaskRepository` | `infra/outbound/sqlite` | Persist tasks |
| `WorktreeReader`  | `infra/outbound/git`    | Discover worktrees in a repo |
| `PrGateway`       | `infra/outbound/gh`     | Look up PR by branch |
| `IssueGateway`    | `infra/outbound/linear` | Fetch issue by external id (multi-impl) |
| `Clock`           | `main.zig` (SystemClock) | Current time, fakeable in tests |

### Use cases (`application/use_cases/`)

Each use case is a struct holding the ports it needs, with a single `execute` method. Inbound adapters call only these.

```zig
pub const AddTodo        = struct { tasks: TaskRepository, clock: Clock, …
                                    pub fn execute(self, input: AddTodoInput) !Task };
pub const ListTasks      = struct { tasks: TaskRepository,                   …
                                    pub fn execute(self, filter: TaskFilter) ![]TaskView };
pub const LinkTaskToWorktree = struct { … };
pub const ArchiveTask    = struct { … };
pub const DeleteTask     = struct { … };
pub const UpdateTask     = struct { … };
pub const RefreshAll     = struct {
    tasks: TaskRepository,
    worktrees: WorktreeReader,
    prs: PrGateway,
    issues: []const IssueGateway,
    clock: Clock,
    pub fn execute(self, repos: []const Repo) !RefreshReport;
};
```

`TaskView = Task + derived Status`, prepared for display.

### `RefreshAll` orchestration

The only non-trivial flow. Sequential per repo:

```
for each configured repo:
    1. discovered = WorktreeReader.list(repo)
    2. upsert worktrees by (repo_id, branch); update head_sha + last_seen_at;
       mark previously-known worktrees not in `discovered` as gone
    3. for each worktree: ensure a Task exists
         - if a Task has branch_hint == worktree.branch and worktree_id == NULL: link it
         - else if no Task points at this worktree: create one (title = branch)
    4. for each task with a linked worktree:
         pr = PrGateway.find_by_branch(repo, branch)
         upsert PR; attach pr_id to task; clear if PR vanished
    5. for each task missing an issue link:
         maybe_ref = parse_ticket(branch_or_branch_hint, configured_patterns)
         if matched: IssueGateway[provider].fetch(ref.external_id); upsert; attach

returns RefreshReport { tasks_created, prs_updated, issues_updated, errors[] }
```

Errors per repo/task accumulate into `RefreshReport.errors[]`; the refresh never short-circuits on one bad repo or Linear hiccup.

### Composition root (`main.zig`)

```zig
const cfg = try config.load(allocator);
var db    = try SqliteTaskRepository.open(allocator, cfg.db_path);
var git   = GitWorktreeReader.init();
var gh    = GhPrGateway.init();
var lin   = LinearIssueGateway.init(allocator, cfg.linear_token);
const clock = SystemClock{};

var use_cases = UseCases{
    .add_todo      = .{ .tasks = db.interface(), .clock = clock.interface() },
    .list_tasks    = .{ .tasks = db.interface() },
    .link_worktree = .{ .tasks = db.interface() },
    .refresh_all   = .{
        .tasks     = db.interface(),
        .worktrees = git.interface(),
        .prs       = gh.interface(),
        .issues    = &.{ lin.interface() },
        .clock     = clock.interface(),
    },
    // …
};

switch (args.command) {
    .none        => try tui.run(allocator, &use_cases),
    .list   => |a| try cli.list(allocator, &use_cases, a),
    .add    => |a| try cli.add(allocator, &use_cases, a),
    .mcp         => try mcp.serve(allocator, &use_cases),
    // …
}
```

## 7. Inbound surfaces

### TUI (`infra/inbound/tui`)

libvaxis. Kanban layout, 4 columns:

```
┌─ ctt ─────────────────────────── repo: [all] ─ last refresh: 14:22 ──┐
│ TODO (3)       │ IN PROGRESS (5) │ IN REVIEW (4)   │ DONE (12)        │
├────────────────┼─────────────────┼─────────────────┼──────────────────┤
│ • refactor X   │ ▶ MOE-272 ebay  │ #141 api-refin  │ ✓ MOE-181 auth   │
│   feat/x       │   feat/ebay-... │   open · 2d     │   merged 3d ago  │
│ • MOE-301 …    │   pushed, no PR │ #156 poshmark   │ ✓ fix queue cap  │
│ • blog post    │ ▶ fix-queue-cap │   draft         │   merged 5d ago  │
│                │   no commits    │                 │                  │
└────────────────┴─────────────────┴─────────────────┴──────────────────┘
  [a]dd  [r]efresh  [o]pen PR  [O]pen issue  [l]ink  [A]rchive  [d]elete  [/]filter  [?]help  [q]uit
```

Keys:

| Key | Action |
|---|---|
| `h/j/k/l` / arrows | Navigate within / between columns |
| `enter` | Open detail panel for selected task |
| `a` | Add Todo (modal: title, branch hint, issue id) |
| `r` | Refresh (calls `RefreshAll`) |
| `o` / `O` | Open PR url / issue url in `$BROWSER` |
| `l` | Link task → worktree / pr / issue (modal) |
| `e` | Edit title / notes |
| `A` | Archive (toggle) |
| `d` | Delete (confirm) |
| `/` | Filter by repo or text |
| `?` | Help |
| `q` | Quit |

Per-card hints (derived in `domain/services/hints.zig` from `Worktree` + `Pr`):
- In-progress:
  - `no commits` when `commits_ahead_of_default == 0`
  - `N commits ahead, not pushed` when `commits_ahead_of_default > 0` and `!has_upstream`
  - `pushed, no PR` when `has_upstream`, `commits_ahead_of_upstream == 0`, and no PR
  - `N unpushed commits` when `has_upstream` and `commits_ahead_of_upstream > 0`
- In-review: PR number, state (`open`/`draft`), age since `pr.updated_at`
- Done: `merged|closed` + age since `pr.updated_at`

Refresh runs synchronously on launch with a "refreshing…" spinner. Manual refresh via `r` happens on a background thread; the result is posted to the UI thread via `std.Thread.Channel`. No background poller.

### CLI (`infra/inbound/cli`)

`ctt` with no subcommand launches the TUI. Every subcommand supports `--json`. Errors → stderr. Exit codes: `0` ok, `1` user error, `2` system error.

```
ctt                                            # launch TUI
ctt add "refactor X" [--branch feat/x] [--issue MOE-301]
ctt list [--status todo|in-progress|in-review|done|archived] [--repo NAME] [--json]
ctt show <id> [--json]
ctt update <id> [--title T] [--branch-hint B] [--notes N]
ctt link <id> [--worktree PATH] [--pr URL_OR_NUMBER] [--issue ID]
ctt unlink <id> [--worktree | --pr | --issue]
ctt archive <id>             # toggle
ctt delete <id>
ctt refresh
ctt open <id> [--pr | --issue]
ctt config repo add <path>
ctt config repo list
ctt config repo remove <name>
ctt config linear set-token <token>
ctt mcp                      # JSON-RPC 2.0 over stdio
```

### MCP server (`infra/inbound/mcp`)

`ctt mcp` speaks MCP (JSON-RPC 2.0) over stdio. Tool surface mirrors the CLI 1:1:

| Tool | Args | Returns |
|---|---|---|
| `ctt_list_tasks` | `{ status?, repo? }` | `Task[]` |
| `ctt_get_task`   | `{ id }` | `Task` |
| `ctt_add_todo`   | `{ title, branch_hint?, issue_id? }` | `Task` |
| `ctt_update_task`| `{ id, title?, branch_hint?, notes? }` | `Task` |
| `ctt_link_task`  | `{ id, worktree?, pr?, issue? }` | `Task` |
| `ctt_unlink_task`| `{ id, target: "worktree"\|"pr"\|"issue" }` | `Task` |
| `ctt_archive_task`| `{ id, archived: bool }` | `Task` |
| `ctt_delete_task`| `{ id }` | `{ deleted: true }` |
| `ctt_refresh`    | `{}` | `RefreshReport` |
| `ctt_open_url`   | `{ id, target: "pr"\|"issue" }` | `{ url: string }` (does NOT spawn browser) |

Each handler is a 5-line shim: deserialize args → call a use case → serialize result.

## 8. Outbound providers

### Ticket parsing (pure, `domain/services/ticket.zig`)

```zig
pub const TicketRef = struct { provider: ProviderId, external_id: []const u8 };

pub fn parse(branch: BranchName, patterns: []const ProviderPattern) ?TicketRef;
```

Patterns from config; first match wins. Default ships with one for Linear-style ids:

```json
{ "provider": "linear", "regex": "(?i)\\b([a-z]{2,6})-(\\d+)\\b" }
```

### Linear adapter (`infra/outbound/linear`)

- **Transport:** `std.http.Client` → `https://api.linear.app/graphql`.
- **Auth:** `CTT_LINEAR_TOKEN` env var → falls back to `~/.config/ctt/secrets.json` (file mode `0600`, enforced on read).
- **Query** (one round trip per issue, cached in `issues.fetched_at`):
  ```graphql
  query($id: String!) {
    issue(id: $id) {
      identifier
      url
      title
      state { name }
    }
  }
  ```
- **Cache TTL:** 5 minutes inside a single session, configurable. `ctt refresh` bypasses cache.
- **Rate limiting:** in-process token bucket; respects `Retry-After`.
- **Error handling:** failures land in `RefreshReport.errors[]`; existing issue link is preserved.

### gh PR gateway (`infra/outbound/gh`)

Shell out:
```
gh pr list --repo <owner/name> --head <branch> --state all \
    --json number,url,title,headRefName,state,isDraft,updatedAt --limit 1
```

Mapping:
- `state: "OPEN"` + `isDraft: true`  → `PrState.draft`
- `state: "OPEN"` + `isDraft: false` → `PrState.open`
- `state: "MERGED"`                  → `PrState.merged`
- `state: "CLOSED"`                  → `PrState.closed`

Owner/name comes from the `repos.github` column (set on `ctt config repo add` from the repo's `origin` remote).

### Git worktree reader (`infra/outbound/git`)

Per repo:
1. `git -C <repo_root> worktree list --porcelain` → list of `{ path, branch, head_sha }`.
2. For each worktree, additionally:
   - `git -C <path> rev-list --count <default_branch>..HEAD` → `commits_ahead_of_default`
   - `git -C <path> rev-parse --abbrev-ref --symbolic-full-name @{u}` (exit 0 ⇒ `has_upstream = true`)
   - if upstream exists: `git -C <path> rev-list --count @{u}..HEAD` → `commits_ahead_of_upstream`

Returns `[]WorktreeSnapshot` with all fields populated. Failures on per-worktree subqueries default to safe values (0 / false / null) and are logged but do not fail the discovery.

### Adding a new provider (Jira, GitHub Issues)

1. Add `infra/outbound/jira/` module implementing `IssueGateway`.
2. Add a config entry under `providers.jira` (base URL, auth).
3. Add a `providers.patterns` entry for the branch-name regex.
4. Register it in `main.zig`'s composition root.

`domain`, `application`, and other infra do not change.

## 9. Config, errors, logging

### Config

`~/.config/ctt/config.json`. Human-editable; mutated by `ctt config …` subcommands.

```json
{
  "db_path": "~/.config/ctt/db.sqlite",
  "default_browser": "$BROWSER",
  "repos": [
    {
      "name": "moe-backend",
      "path": "/Users/domingo/tru4m/moe-backend",
      "github": "tru4m/moe-backend",
      "default_branch": "main"
    },
    {
      "name": "moe-mobile-app",
      "path": "/Users/domingo/tru4m/moe-mobile-app",
      "github": "tru4m/moe-mobile-app"
    }
  ],
  "providers": {
    "linear": { "enabled": true },
    "patterns": [
      { "provider": "linear", "regex": "(?i)\\b([a-z]{2,6})-(\\d+)\\b" }
    ]
  },
  "refresh": { "issue_cache_ttl_secs": 300 }
}
```

Load order (highest wins): env vars → `config.json` → defaults. Loaded `Config` is a value type in `domain/value_objects/config.zig`; parsing lives in `infra/outbound/config`.

### Errors

- `domain` uses typed Zig error sets per port (`TaskRepository.Error`, `PrGateway.Error`, etc.).
- Adapters map internal errors into the port's set.
- `RefreshAll` aggregates failures into `RefreshReport.errors[]`; it never returns an error itself for partial failure.
- `main.zig` is the only place that catches top-level errors and prints them.

### Logging

`std.log` with scoped loggers (`std.log.scoped(.refresh)`, `.tui`, `.gh`, `.linear`). Default level `warn`; `CTT_LOG=info|debug` raises it. The TUI captures logs into an in-memory ring buffer surfaced by the `?` help screen; nothing writes to stdout while libvaxis owns the terminal.

## 10. Testing strategy

| Layer | What to test | How |
|---|---|---|
| `domain` services (status derivation, ticket parsing) | Pure functions | Plain `test "…"` blocks |
| `application` use cases | Orchestration logic | In-memory fake adapters (structs that fill in a vtable) |
| `infra/outbound/sqlite` | Schema + queries | Integration tests against a temp-file DB per test |
| `infra/outbound/git` | Porcelain parsing | Fixture: tarball of a tiny repo with worktrees; `std.fs.tmpDir` |
| `infra/outbound/gh` | Output JSON shape | Snapshot of `gh pr list` JSON; parser test only (no fork) |
| `infra/outbound/linear` | GraphQL client | Spin up local `std.net.Server` mock; recorded fixtures |
| `infra/inbound/cli` | Arg parsing → use case call | Fake `UseCases` struct; assert dispatch |
| `infra/inbound/mcp` | Tool schema + dispatch | Same fake-use-cases approach |
| `infra/inbound/tui` | View rendering | libvaxis test backend; snapshot strings |

CI runs `zig build test` across the workspace. No live network or real `gh`/Linear calls — those are smoke-tested locally only.

## 11. Packaging & install

- Local dev: `zig build install --prefix ~/.local`.
- Release: `zig build -Doptimize=ReleaseSafe`. Cross-compile to `aarch64-macos`, `x86_64-linux-gnu` via Zig's built-in toolchain. Publish binaries as GitHub release artifacts.
- Brew tap deferred to v1.1.
- MCP registration: README snippet showing how to add `ctt mcp` to `~/.claude.json`.

## 12. Open questions / deferred to v1.1

- OS keychain for Linear token via `@cImport(<Security/Security.h>)`.
- Jira and GitHub-Issues adapters.
- Linear write-back (transition issue state when PR merges).
- Background polling.
- Brew tap.
