pub const v1: [*:0]const u8 =
    \\CREATE TABLE IF NOT EXISTS repos (
    \\    id INTEGER PRIMARY KEY,
    \\    name TEXT NOT NULL UNIQUE,
    \\    root_path TEXT NOT NULL UNIQUE,
    \\    github TEXT,
    \\    default_branch TEXT NOT NULL DEFAULT 'main'
    \\);
    \\CREATE TABLE IF NOT EXISTS worktrees (
    \\    id INTEGER PRIMARY KEY,
    \\    repo_id INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    \\    path TEXT NOT NULL UNIQUE,
    \\    branch TEXT NOT NULL,
    \\    head_sha TEXT NOT NULL,
    \\    commits_ahead_of_default INTEGER NOT NULL DEFAULT 0,
    \\    has_upstream INTEGER NOT NULL DEFAULT 0,
    \\    commits_ahead_of_upstream INTEGER,
    \\    last_seen_at TEXT NOT NULL,
    \\    UNIQUE (repo_id, branch)
    \\);
    \\CREATE TABLE IF NOT EXISTS prs (
    \\    id INTEGER PRIMARY KEY,
    \\    repo_id INTEGER NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
    \\    number INTEGER NOT NULL,
    \\    url TEXT NOT NULL,
    \\    title TEXT NOT NULL,
    \\    head_branch TEXT NOT NULL,
    \\    state TEXT NOT NULL CHECK (state IN ('open','draft','merged','closed')),
    \\    updated_at TEXT NOT NULL,
    \\    fetched_at TEXT NOT NULL,
    \\    UNIQUE (repo_id, number)
    \\);
    \\CREATE TABLE IF NOT EXISTS issues (
    \\    id INTEGER PRIMARY KEY,
    \\    provider TEXT NOT NULL,
    \\    external_id TEXT NOT NULL,
    \\    url TEXT,
    \\    title TEXT,
    \\    state TEXT,
    \\    fetched_at TEXT NOT NULL,
    \\    UNIQUE (provider, external_id)
    \\);
    \\CREATE TABLE IF NOT EXISTS tasks (
    \\    id INTEGER PRIMARY KEY,
    \\    title TEXT NOT NULL,
    \\    branch_hint TEXT,
    \\    worktree_id INTEGER REFERENCES worktrees(id) ON DELETE SET NULL,
    \\    pr_id INTEGER REFERENCES prs(id) ON DELETE SET NULL,
    \\    issue_id INTEGER REFERENCES issues(id) ON DELETE SET NULL,
    \\    archived INTEGER NOT NULL DEFAULT 0,
    \\    notes TEXT,
    \\    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    \\    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    \\);
    \\PRAGMA user_version = 1;
;
