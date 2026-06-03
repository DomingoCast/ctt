# ctt — TUI Polish v1 (Design)

**Date:** 2026-06-03
**Status:** Approved design, not yet implemented
**Builds on:** `2026-06-02-ctt-claude-task-tracker-design.md`, `2026-06-03-ctt-handoff-resume-design.md`

## 1. Overview

The TUI shipped functional but unpolished. Two concrete problems:

- **External writes aren't visible.** Adding a task via the CLI or MCP server doesn't surface in the running TUI without pressing `g` (refresh). For an LLM-driven workflow where multiple processes touch the same DB, this is a coordination gap.
- **Cards look cramped.** Each task renders as a single wrapped line inside its column. No per-card border, no breathing room, no visual signal of state beyond the column it's in.

This spec covers two coordinated changes:

1. **Auto-refresh** — a periodic poll plus a terminal-focus event hook so the TUI stays current with external writes.
2. **Card redesign** — rounded bordered cards with column-accent status pips, state-aware footer content, Nerd Font glyphs, and a Tokyo-Night-inspired color scheme. Detail panel, modals, and footer get the same visual treatment so the whole TUI feels coherent.

## 2. Goals

- External writes (CLI, MCP, another `ctt` instance) appear in the running TUI within ~2 seconds with zero user action.
- Switching back to the ctt terminal window refreshes immediately, not after the next poll tick.
- Each task is a visually distinct, scannable unit with at-a-glance signal for state, branch, PR/issue links, and live LLM session.
- Visual style is consistent across kanban, detail panel, modals, and footer.
- Provider icons, accent colors, and glyph use degrade cleanly on terminals without Nerd Fonts or truecolor.

## 3. Non-goals (v1)

- Animated transitions between refreshes (no card-slide effects; refresh is a full re-render).
- Mouse support (vaxis supports it; not in v1).
- Per-task tag colors (only column accents).
- A "compact mode" that disables borders.
- Bordered cards that grow to fit multi-line titles. Titles are single-line with `…` truncation.
- Handoff retention/pruning (still parked in the handoff/resume spec).
- A separate "card" config knob hierarchy beyond what's listed in §7. No per-column padding override, no individual border-style toggles.

## 4. Auto-refresh

### 4.1 Triggers

Three trigger sources, all routed through the existing `doRefresh` function:

1. **Periodic poll** — every `ui.refresh_interval_ms` (default 2000ms). Driven by `vaxis.Loop` timer events. Skipped when `state.mode != .normal` (no surprise list reorders while the user is mid-modal).
2. **Focus-in event** — when the terminal regains focus (user switches to the ctt window/tab), an immediate `doRefresh` regardless of `state.mode`. vaxis emits this via `.focus_in` when the terminal advertises support; supported by iTerm2, kitty, alacritty, wezterm, Terminal.app.
3. **Own writes** — unchanged. `add`, `archive`, `delete`, handoff-save, `r`, `R` still call `doRefresh` inline immediately after the write.

### 4.2 mtime guard

`doRefresh` stats the DB file before running its SQL load:

```zig
const stat = std.fs.cwd().statFile(uc.io, db_path) catch return;
if (!force and stat.mtime == state.last_db_mtime) return;
state.last_db_mtime = stat.mtime;
// ... existing refresh body ...
```

`force = true` for own-writes and focus-in (defensive — own writes always update mtime but we shouldn't rely on filesystem granularity, and focus-in benefits the user even if mtime is unchanged from their last visit). `force = false` for the periodic poll, so idle polls are essentially free.

The new `state.last_db_mtime` field is a `i128` (nanoseconds since epoch, matching `std.fs.File.Stat.mtime`).

### 4.3 Refresh pulse

A small visual indicator in the footer (bottom-right corner) shows when refresh is in flight:

- `●` dim grey when idle
- `●` bright accent + cycling-frame spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) when `state.refreshing == true`
- Resets to dim immediately after refresh returns

Provides a "this app is alive" signal even when no data is changing.

## 5. Card visual treatment

### 5.1 Shape

Each task is its own bordered sub-window inside the column. Cards use 1-cell horizontal and vertical padding inside their borders. Empty row between adjacent cards.

**Normal card:**

```
╭─────────────────────╮
│ ● Try out ctt       │
│    feat/smoke      │
╰─────────────────────╯
```

**Selected card:**

```
╔═════════════════════╗
║ ◉ wire MCP          ║
║    feat/mcp        ║
╚═════════════════════╝
```

Border characters:
- Normal: `╭ ╮ ╰ ╯ ─ │`
- Selected: `╔ ╗ ╚ ╝ ═ ║` in the column's accent color (brighter shade than the pip)

Selection unit is the whole card box. Navigation: `h`/`l` cross columns, `j`/`k` card-to-card within a column.

### 5.2 Status pip

Top-left, inside the card, first character of the title row:

- Normal: `●` in the column accent color (dim shade)
- Selected: `◉` in the column accent color (bright shade)

### 5.3 Color palette (Tokyo Night-inspired)

| Element | Color (truecolor RGB) | 256-color fallback |
|---|---|---|
| TODO accent | `#7aa2f7` (slate blue) | 110 |
| IN PROGRESS accent | `#e0af68` (amber) | 179 |
| IN REVIEW accent | `#bb9af7` (violet) | 141 |
| DONE accent | `#9ece6a` (green) | 149 |
| Title | `#c0caf5` (bright white) | 189 |
| Metadata | `#565f89` (dim slate) | 60 |
| Idle pulse | `#414868` (very dim) | 59 |
| Refreshing pulse | accent of the focused column | — |

Each color has a "dim" and "bright" variant for the unselected/selected card states; the bright variant is the RGB above, the dim variant is the same hue with each RGB channel multiplied by 0.6 (then clamped to `[0,255]`). Computed at render time, not stored.

Column headers ("TODO", "IN PROGRESS", "IN REVIEW", "DONE") use the column accent color, bold.

Background stays terminal-default (no card fill). Detail panel and modals use the same default background with bordered framing.

All colors are overridable via `ui.color_scheme.*` in config (see §7).

### 5.4 Nerd Font glyphs

Used in the metadata footer line and detail panel field labels:

| Concept | Glyph | Nerd Font name |
|---|---|---|
| Branch | ` ` | nf-cod-source_control |
| Worktree (folder) | ` ` | nf-cod-folder |
| PR | ` ` | nf-cod-git_pull_request |
| Issue | ` ` | nf-cod-issues |
| Generic AI / LLM fallback | ` ` | nf-cod-robot |
| Edit (handoff modal header) | ` ` | nf-cod-edit |
| Save (modal footer hint) | ` ` | nf-cod-save |

Provider icons stay config-driven via `providers.templates.<name>.icon`. If that field is unset, the fallback is `` plus the first uppercase letter of the provider name (e.g. ` C` for "claude").

**Fallback when `ui.use_nerd_glyphs = false`** (terminals without Nerd Font):

| Concept | ASCII fallback |
|---|---|
| Branch | `b:` |
| Worktree | `r:` |
| PR | `pr:` |
| Issue | `i:` |
| AI fallback | `[AI]` |
| Edit | `[edit]` |
| Save | `[save]` |

`use_nerd_glyphs` defaults to `true` (user explicitly asked for nerd fonts).

## 6. State-aware card content

Title line is uniform: `[provider_icon] [status_pip] <title>`, truncated with `…` at card width.

Footer line is dim, per-column:

| Column | Footer fields (in order) |
|---|---|
| TODO | ` <branch_hint>` or `—` if absent |
| IN PROGRESS | ` <worktree-repo-name>` + ` <commits_ahead_of_default>↑` if non-zero |
| IN REVIEW | PR status pip (`●` open / `◐` draft / `○` closed-not-merged) + ` #<number>` + ` <issue-key>` if linked |
| DONE | ` <relative-time>` since `pr.updated_at` if PR present, else `task.updated_at` |

Relative time formatting: `<60s` → "just now", `<60m` → "Nm", `<24h` → "Nh", `<30d` → "Nd", else "Nmo" / "Ny". One unit only ("2d", not "2d 4h").

If a card has `task.session` set, the provider icon (per §5.4) renders before the status pip on the title line: `[icon] ● <title>`.

Truncation rule: if `[icon + pip + title]` exceeds card_width - 2 (for left/right padding), the title is truncated with `…`. The icon and pip are never truncated.

## 7. Config additions

In `~/.config/ctt/config.json`:

```jsonc
{
  "ui": {
    "spawn": "...",                        // existing — unchanged
    "refresh_interval_ms": 2000,           // NEW; default 2000; clamped to [500, 60000]
    "use_nerd_glyphs": true,               // NEW; default true
    "color_scheme": {                      // NEW; all optional
      "todo": "#7aa2f7",
      "in_progress": "#e0af68",
      "in_review": "#bb9af7",
      "done": "#9ece6a",
      "title": "#c0caf5",
      "metadata": "#565f89",
      "idle_pulse": "#414868"
    }
  }
}
```

Color values are `#rrggbb` hex strings. Invalid values → `error.BadFormat` on load (existing pattern). Missing fields → fall back to the defaults in §5.3.

`refresh_interval_ms` outside `[500, 60000]` clamps to the bound (no error). Prevents thrashing or unbounded staleness.

## 8. Other surfaces aligned

### 8.1 Detail panel (Enter)

Same visual language as cards:

- Rounded `╭ ╮ ╰ ╯` border in the column accent of the source task.
- Section headers (`Session`, `Worktree`, `PR`, `Issue`, `Handoffs`) in bright bold (`title` color).
- Field labels use Nerd Font glyphs from §5.4. Values on the same line, normal weight.
- Handoff entries separated by `╾──────────────╼` with the relative timestamp right-aligned in dim.

### 8.2 Modals

`H` handoff modal:

- Rounded border in the title color (neutral, not column-tied).
- Header: ` Handoff for #<id>` bold.
- Footer hint: ` Ctrl-S save · Esc cancel` dim, right-aligned.

`n` add-todo modal: same treatment, header is ` New task` bold.

### 8.3 Footer status bar

- Last message text (existing) left-aligned, dim metadata color.
- Refresh pulse (§4.3) right-aligned, spans last 2-3 cells.

## 9. Files touched

- `src/infra/inbound/tui/view.zig` — bulk of rendering: new card render function, color helpers, glyph helpers, detail panel, footer pulse.
- `src/infra/inbound/tui/app.zig` — event loop additions: timer arm for poll, focus-in arm, refresh-call routing with `force` flag.
- `src/infra/inbound/tui/state.zig` — new fields: `last_db_mtime: i128`, `spinner_frame: u8`, possibly `refresh_force_pending: bool`.
- `src/infra/inbound/tui/modal.zig` — aesthetic update for handoff + add-todo modals.
- `src/infra/outbound/config/loader.zig` — new fields under `UiConfig`: `refresh_interval_ms`, `use_nerd_glyphs`, `color_scheme`.
- `src/main.zig` — read the new `ui.refresh_interval_ms`, `ui.use_nerd_glyphs`, and `ui.color_scheme` from config and pass them through `tui.UseCases` (new fields on that struct).
- `src/infra/inbound/tui/use_cases.zig` — pass through new config values (refresh interval, glyph mode, colors).

## 10. Testing strategy

- **Domain & application:** no changes; no new tests needed there.
- **Config loader:** add tests for `refresh_interval_ms` clamping, `use_nerd_glyphs` default, `color_scheme` partial-override.
- **Pure helpers (in view.zig or a new `card_layout.zig`):**
  - `cardFooterFields(task, status, now) → []FooterField` — unit tests per column.
  - `formatRelativeTime(unix_secs, now) → []const u8` — boundary cases (just-now, 1m, 59m, 1h, 23h, 1d, 29d, 1mo, 11mo, 1y).
  - `truncateWithEllipsis(text, max_width) → []const u8` — short, exact-fit, over.
  - `colorForColumn(status, scheme) → vaxis.Color` — default + override paths.
  - `shouldRefresh(last_mtime, current_mtime, force) → bool` — all four combinations.
- **State-machine tests** (TUI app.zig existing pattern):
  - Poll timer arm calls `doRefresh` when `state.mode == .normal`.
  - Poll timer arm skips `doRefresh` when in a modal.
  - Focus-in event calls `doRefresh` regardless of mode.
- **No automated visual tests.** Card rendering is verified by manual smoke (`ctt` in a real terminal, eyeball check).

## 11. Migration

No schema change. New config fields have defaults; existing user configs continue to parse unchanged.

If a user has a config without `ui` at all, `UiConfig.{}` defaults apply (refresh on, nerd glyphs on, Tokyo Night palette).

## 12. Out of scope (parked for follow-ups)

- **Mouse support** — vaxis supports it; not v1.
- **Per-task tag colors** — only column-tied accents in v1.
- **Animated transitions** — full re-render on refresh.
- **Card density mode** — single aesthetic; live with it.
- **Card multi-line titles** — single-line + ellipsis only.
- **Handoff retention** — still parked from the handoff/resume spec.

## 13. Acknowledged unknowns

1. **vaxis focus-event support.** vaxis 0.6 emits `.focus_in` / `.focus_out` events when the terminal advertises support via `\e[?1004h`. Implementation must enable it; if it doesn't work on user's terminal, the periodic poll still covers the use case.
2. **Nerd Font availability.** No runtime detection. `use_nerd_glyphs` is a config toggle; user opts out if their terminal can't render the glyphs.
3. **Truecolor support.** vaxis falls back to 256-color automatically for terminals without truecolor. If the user has a 16-color terminal, colors may look off but TUI still functions.
