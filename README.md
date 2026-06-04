# ctt — Claude Task Tracker

A terminal tool for tracking AI-assisted development work across multiple repositories. Each unit of work is a **Task**. Tasks are usually backed by a git worktree; some start life as standalone Todos before a worktree exists.

`ctt` exposes three surfaces over the same SQLite database:

- A **Kanban TUI** for the human (4 columns: TODO / IN PROGRESS / IN REVIEW / DONE)
- A **CLI** with JSON output for scripts
- An **MCP server** so Claude (or any MCP-speaking client) can read and write the task list directly

## Quick start

### Build

Requires Zig 0.16.

```sh
git clone https://github.com/tru4m/ctt /path/to/ctt
cd /path/to/ctt
zig build -Doptimize=ReleaseSafe
```

The binary lands at `zig-out/bin/ctt`. Copy it onto your `$PATH`, or run:

```sh
zig build install --prefix ~/.local      # → ~/.local/bin/ctt
```

### Minimal config

Create `~/.config/ctt/config.json`:

```jsonc
{
  "db_path": "/Users/you/.config/ctt/db.sqlite",
  "repos": [],
  "providers": {
    "patterns": [{"provider": "linear", "prefix_min": 2, "prefix_max": 6}]
  }
}
```

That's enough to launch the TUI and create tasks. SQLite is created on first run.

### Run

```sh
ctt              # launches the TUI
ctt list         # plain CLI list
ctt list --json  # machine-readable
```

## TUI keybindings

Press `?` inside the TUI for the live cheatsheet.

| Key | Action |
|---|---|
| `h` / `l` | move between columns |
| `j` / `k` | move within column |
| `Enter` | open task detail panel |
| `n` | new task (Tab cycles Title → Branch → Issue → Project) |
| `r` | resume task in LLM (uses session handle if set, else fresh+context) |
| `R` | force fresh + context |
| `H` | add handoff note (multi-line, Ctrl-S to save) |
| `A` | archive selected |
| `d` | delete selected |
| `o` | open PR in browser |
| `g` | refresh now |
| `?` | toggle help |
| `q` | quit |
| `Esc` | close any overlay |

## CLI subcommands

```sh
ctt add "title" [--branch <name>] [--issue <KEY>] [--project <path>]
ctt list [--json] [--status todo|in-progress|in-review|done|archived] [--repo <name>]
ctt show <id> [--json]
ctt update <id> [--title ...] [--branch-hint ...] [--notes ...]
ctt link <id> [--worktree <path>] [--pr <url>] [--issue <KEY>]
ctt archive <id>
ctt delete <id>
ctt refresh

# Handoff & resume
ctt session set <id> <provider> <session-id>
ctt session clear <id>
ctt handoff <id> --note "summary"
ctt handoff <id>                    # multi-line from stdin
ctt handoff <id> --list [--json]
ctt handoff <id> --latest
ctt context <id> [--json] [--handoffs N]
ctt resume <id> [--print] [--fresh]

# MCP server (stdio JSON-RPC)
ctt mcp
```

## Configuration reference

Full annotated `config.json`:

```jsonc
{
  // Required
  "db_path": "/Users/you/.config/ctt/db.sqlite",

  // Configured repos for the project picker + refresh
  "repos": [
    {"name": "ctt", "path": "/Users/you/projects/ctt", "github": "tru4m/ctt"}
  ],

  // Providers
  "providers": {
    // Ticket-prefix patterns for the Linear adapter
    "patterns": [
      {"provider": "linear", "prefix_min": 2, "prefix_max": 6}
    ],

    // Default LLM provider name. Falls back to "claude" if unset.
    "default": "claude",

    // Per-provider command templates for `ctt resume` / TUI `r`
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

  // TUI options
  "ui": {
    // Wraps the rendered resume command for terminal spawning
    "spawn": "tmux new-window -- {{cmd}}",

    // Auto-refresh poll interval (clamped to [500, 60000])
    "refresh_interval_ms": 2000,

    // Whether to use Nerd Font glyphs in the TUI
    "use_nerd_glyphs": true,

    // Optional Tokyo Night palette overrides
    "color_scheme": {
      "todo":        "#7aa2f7",
      "in_progress": "#e0af68",
      "in_review":   "#bb9af7",
      "done":        "#9ece6a"
    }
  }
}
```

### Built-in defaults

`ctt` ships with a built-in `claude` template, so the TUI's `r` key works out of the box without any config:

- `resume`: `claude --resume {{session_id}}`
- `fresh`: `claude --append-system-prompt "$(cat {{context_file}})"`
- `icon`: `C`

Anything you set in `config.json` overrides these field-by-field.

### Secrets

The Linear token can be supplied two ways (env var wins):

```sh
export CTT_LINEAR_TOKEN=lin_api_…
```

Or `~/.config/ctt/secrets.json` (must be mode `0600` or stricter):

```json
{"linear_token": "lin_api_…"}
```

## MCP setup

Register the server with Claude Code:

```sh
claude mcp add ctt /absolute/path/to/zig-out/bin/ctt mcp
```

Then restart Claude Code. The following tools become available:

- `ctt_list_tasks` — filter by status or repo
- `ctt_get_task` / `ctt_add_todo` / `ctt_update_task` / `ctt_archive_task` / `ctt_delete_task`
- `ctt_refresh`
- `ctt_set_session_handle` / `ctt_clear_session_handle`
- `ctt_add_handoff` / `ctt_list_handoffs`
- `ctt_get_context` — bundled task + session + handoffs for fast warm-resume

## Workflows

### Cold-start resume (TUI)

You have the TUI open, a task is selected, you hit `r`. ctt:

1. Loads the task's stored `(provider, session_id)` handle (if set) and latest handoff body.
2. Renders the `providers.templates.<provider>.resume` command with `{{session_id}}` substituted.
3. Wraps it in `ui.spawn` (e.g. `tmux new-window -- {{cmd}}`).
4. Spawns the child with the task's `project_path` as its cwd.

If no session handle is stored, falls back to the `fresh` template + handoff written to a temp file.

### Warm-continue (inside a Claude session)

You're already in Claude and ask "what's on my plate?":

1. Claude calls `ctt_list_tasks` (via MCP).
2. You pick a task: "let's work on #7."
3. Claude calls `ctt_get_context(7)` — gets task fields, session handle, links, all handoffs.
4. Claude reads the latest handoff and picks up in the current session.
5. Before stopping, Claude calls `ctt_add_handoff(7, "...")` and `ctt_set_session_handle(7, "claude", "<my-id>")` so the next session can pick up.

## Architecture

Hexagonal (ports and adapters), enforced at compile time by `build.zig`:

```
src/
├── domain/                  # pure, std-only
│   ├── entities/            # Task, Repo, Worktree, Pr, Issue
│   ├── value_objects/       # ids, branch_name, sha, timestamp, url, session_handle
│   ├── ports/               # vtable interface structs
│   └── services/            # status derivation, ticket parsing
├── application/             # use cases; depends only on domain
│   └── use_cases/
├── infra/
│   ├── inbound/             # driving adapters (CLI, MCP, TUI)
│   └── outbound/            # driven adapters (sqlite, git, gh, linear, config)
└── main.zig                 # composition root
```

Domain code never imports infra. The composition root in `main.zig` is the only place that wires everything together.

## Development

```sh
zig build test       # ~189 tests
./tests/smoke.sh     # end-to-end CLI smoke
zig build            # debug build
```

## License

MIT — see [LICENSE](./LICENSE).
