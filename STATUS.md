# ctt Status

Snapshot of what's shipped and what's still pending. Updated 2026-06-03.

## Shipped on `main`

### Original v1 spec (`docs/superpowers/specs/2026-06-02-ctt-claude-task-tracker-design.md`)

- ✅ Hexagonal architecture (domain → application → infra) enforced by `build.zig`
- ✅ Domain entities: Task, Repo, Worktree, Pr, Issue + value objects
- ✅ Pure domain services: status derivation, ticket parsing, hint derivation
- ✅ Ports + use cases: AddTodo, ListTasks, GetTask, UpdateTask, DeleteTask, ArchiveTask, Link, RefreshAll
- ✅ SQLite adapter with idempotent migration runner (currently at v3)
- ✅ Linear adapter (GraphQL via `std.http.Client`, env-var-or-file auth with `0600` enforcement, in-process cache)
- ✅ `gh` PR gateway
- ✅ Git worktree reader
- ✅ Inbound: CLI, MCP server (stdio JSON-RPC), TUI kanban
- ✅ Composition root wired in `main.zig`
- ✅ End-to-end smoke (`tests/smoke.sh`)
- ✅ `zig build install --prefix <dir>` produces a working binary

### Beyond original v1 (three follow-up specs)

- ✅ **Per-task handoff & resume** — `(provider, session_id)` handle + append-only handoff log, with cold-start TUI spawn and warm-continue MCP `get_context`. Provider-agnostic via config templates.
- ✅ **TUI polish v1** — periodic auto-refresh + terminal focus events + mtime guard, rounded bordered cards with column-accent status pips, Tokyo Night palette, Nerd Font glyphs with ASCII fallback, detail panel, modals, footer pulse indicator, help overlay (`?`).
- ✅ **Project picker** — `Task.project_path` (SQLite v3), inline fuzzy-match dropdown in the add-todo modal, CLI `--project` flag, resume spawns with `cwd = task.project_path`.
- ✅ **Built-in claude defaults** — `r` works zero-config; anything in `config.json` overrides field-by-field.

### Quality

- 189/189 tests passing on `main`
- Smoke test ends with both `handoff smoke OK` and `project picker smoke OK`
- No memory leaks at smoke runtime (handler-level leaks fixed)
- Three commit-level specs + plans + design docs in `docs/superpowers/`

## Pending for v1 (per spec §11)

### Required

- **Release CI** — `.github/workflows/release.yml` does not exist. Spec calls for cross-compile to `aarch64-macos` + `x86_64-linux-gnu` and publishing GitHub release artifacts. Needs a small spec for the workflow shape (tag triggers, artifact naming, checksums, draft vs published, signing — likely all out-of-scope until needed).
- **License** — `README.md` says `TBD`. Pick one (MIT, Apache-2.0, BSD-3-Clause are typical).

### Nice-to-have

- **Top-level `ctt --help`** — `ctt` with no args launches the TUI; there is no `ctt help` or `--help` subcommand. The TUI's `?` overlay only helps inside the TUI.
- **MCP registration check on first run** — could detect that ctt is being invoked from `claude mcp` and emit a startup banner with config-load info. Skip unless people get confused.

## Explicitly deferred to v1.1 (per spec §12)

- OS keychain for Linear token (macOS Security framework, Linux libsecret)
- Jira adapter
- GitHub-Issues adapter
- Linear write-back (transition issue state when PR merges)
- Background polling for Linear/gh (the TUI's local 2s poll is unrelated; this means a separate refresh daemon)
- Brew tap distribution

## Acknowledged TUI gaps (low-priority, all called out in the final cross-cut review)

- Card-level display of `project_path` — too much for one card row; lives in the detail panel only.
- State-machine tests for the new picker key-handling — manual smoke covers it.
- Application-layer `AddTodo.execute` test for non-null `project_path` — DB integration test + CLI smoke both cover, just not the explicit app-layer test the spec called for.
- TUI in IN REVIEW column: spec called for an inline PR-state pip (`●` open / `◐` draft / `○` closed). Currently shows the PR glyph + number but skips the state pip.

## File map

```
docs/superpowers/
├── specs/
│   ├── 2026-06-02-ctt-claude-task-tracker-design.md
│   ├── 2026-06-03-ctt-handoff-resume-design.md
│   ├── 2026-06-03-ctt-tui-polish-v1-design.md
│   └── 2026-06-03-ctt-project-picker-design.md
└── plans/
    ├── 2026-06-02-ctt-v1.md
    ├── 2026-06-03-ctt-handoff-resume.md
    ├── 2026-06-03-ctt-tui-polish-v1.md
    └── 2026-06-03-ctt-project-picker.md
```

Specs describe what was built; plans describe how. Both committed alongside the implementation.
