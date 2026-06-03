const std = @import("std");
const d = @import("domain");

/// In-memory TaskRepository test double.
/// Uses an internal arena for all string allocations so deinit() is leak-free.
pub const FakeTaskRepo = struct {
    arena: std.heap.ArenaAllocator,
    next_id: i64,
    tasks: std.AutoHashMap(i64, d.Task),
    worktrees: std.AutoHashMap(i64, d.Worktree),
    prs: std.AutoHashMap(i64, d.Pr),
    issues: std.AutoHashMap(i64, d.Issue),
    next_wt_id: i64,
    next_pr_id: i64,
    next_iss_id: i64,

    pub fn init(a: std.mem.Allocator) FakeTaskRepo {
        return .{
            .arena = std.heap.ArenaAllocator.init(a),
            .next_id = 1,
            .tasks = std.AutoHashMap(i64, d.Task).init(a),
            .worktrees = std.AutoHashMap(i64, d.Worktree).init(a),
            .prs = std.AutoHashMap(i64, d.Pr).init(a),
            .issues = std.AutoHashMap(i64, d.Issue).init(a),
            .next_wt_id = 1,
            .next_pr_id = 1,
            .next_iss_id = 1,
        };
    }

    pub fn deinit(self: *FakeTaskRepo) void {
        self.tasks.deinit();
        self.worktrees.deinit();
        self.prs.deinit();
        self.issues.deinit();
        self.arena.deinit();
    }

    pub fn interface(self: *FakeTaskRepo) d.ports.TaskRepository {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = d.ports.TaskRepository.VTable{
        .create = createFn,
        .get    = getFn,
        .list   = listFn,
        .update = updateFn,
        .delete = deleteFn,
        .find_by_branch_hint = findByBranchHintFn,
        .find_by_worktree    = findByWorktreeFn,
        .upsert_worktree     = upsertWorktreeFn,
        .upsert_pr           = upsertPrFn,
        .upsert_issue        = upsertIssueFn,
    };

    fn createFn(p: *anyopaque, _: std.mem.Allocator, draft: d.NewTask) d.ports.TaskRepository.Error!d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        const aa = self.arena.allocator();
        const id_val = self.next_id;
        self.next_id += 1;
        const t = d.Task{
            .id = @enumFromInt(id_val),
            .title = aa.dupe(u8, draft.title) catch return error.OutOfMemory,
            .branch_hint = draft.branch_hint,
            .worktree = null,
            .pr = null,
            .issue = null,
            .archived = false,
            .notes = if (draft.notes) |n| aa.dupe(u8, n) catch return error.OutOfMemory else null,
            .session = null,
            .created_at = .{ .unix_secs = 0 },
            .updated_at = .{ .unix_secs = 0 },
        };
        self.tasks.put(id_val, t) catch return error.OutOfMemory;
        return t;
    }

    fn getFn(p: *anyopaque, _: std.mem.Allocator, id: d.ids.TaskId) d.ports.TaskRepository.Error!?d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        return self.tasks.get(id.raw());
    }

    fn listFn(p: *anyopaque, a: std.mem.Allocator, _: d.TaskFilter) d.ports.TaskRepository.Error![]d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        var out = a.alloc(d.Task, self.tasks.count()) catch return error.OutOfMemory;
        var it = self.tasks.valueIterator();
        var i: usize = 0;
        while (it.next()) |t| : (i += 1) out[i] = t.*;
        return out;
    }

    fn updateFn(p: *anyopaque, _: std.mem.Allocator, id: d.ids.TaskId, patch: d.TaskPatch) d.ports.TaskRepository.Error!d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        const existing = self.tasks.getPtr(id.raw()) orelse return error.NotFound;
        if (patch.title) |v| existing.title = v;
        if (patch.branch_hint) |v| existing.branch_hint = v;
        if (patch.notes) |v| existing.notes = v;
        if (patch.archived) |v| existing.archived = v;
        // Double-optional link patches: outer-some means "set or clear"
        if (patch.worktree_id) |maybe_wt| {
            existing.worktree = if (maybe_wt) |wt_id| self.worktrees.get(wt_id.raw()) else null;
        }
        if (patch.pr_id) |maybe_pr| {
            existing.pr = if (maybe_pr) |pr_id| self.prs.get(pr_id.raw()) else null;
        }
        if (patch.issue_id) |maybe_iss| {
            existing.issue = if (maybe_iss) |iss_id| self.issues.get(iss_id.raw()) else null;
        }
        if (patch.session) |maybe_s| {
            existing.session = maybe_s;
        }
        return existing.*;
    }

    fn deleteFn(p: *anyopaque, id: d.ids.TaskId) d.ports.TaskRepository.Error!void {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        _ = self.tasks.remove(id.raw());
    }

    fn findByBranchHintFn(p: *anyopaque, _: std.mem.Allocator, branch: d.BranchName) d.ports.TaskRepository.Error!?d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        var it = self.tasks.valueIterator();
        while (it.next()) |t| {
            if (t.worktree != null) continue; // already linked
            if (t.branch_hint) |bh| {
                if (std.mem.eql(u8, bh.value, branch.value)) return t.*;
            }
        }
        return null;
    }

    fn findByWorktreeFn(p: *anyopaque, _: std.mem.Allocator, wt_id: d.ids.WorktreeId) d.ports.TaskRepository.Error!?d.Task {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        var it = self.tasks.valueIterator();
        while (it.next()) |t| {
            if (t.worktree) |wt| {
                if (wt.id == wt_id) return t.*;
            }
        }
        return null;
    }

    fn upsertWorktreeFn(p: *anyopaque, _: std.mem.Allocator, repo_id: d.ids.RepoId, snap: d.WorktreeSnapshot) d.ports.TaskRepository.Error!d.ids.WorktreeId {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        // Find existing by (repo_id, branch)
        var it = self.worktrees.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.repo.id == repo_id and
                std.mem.eql(u8, entry.value_ptr.branch.value, snap.branch.value))
            {
                // Update in place
                entry.value_ptr.path = snap.path;
                entry.value_ptr.head_sha = snap.head_sha;
                entry.value_ptr.commits_ahead_of_default = snap.commits_ahead_of_default;
                entry.value_ptr.has_upstream = snap.has_upstream;
                entry.value_ptr.commits_ahead_of_upstream = snap.commits_ahead_of_upstream;
                entry.value_ptr.last_seen_at = .{ .unix_secs = 0 };
                return entry.value_ptr.id;
            }
        }
        // Insert new
        const id_val = self.next_wt_id;
        self.next_wt_id += 1;
        const wt = d.Worktree{
            .id = @enumFromInt(id_val),
            .repo = .{ .id = repo_id, .name = "" },
            .path = snap.path,
            .branch = snap.branch,
            .head_sha = snap.head_sha,
            .commits_ahead_of_default = snap.commits_ahead_of_default,
            .has_upstream = snap.has_upstream,
            .commits_ahead_of_upstream = snap.commits_ahead_of_upstream,
            .last_seen_at = .{ .unix_secs = 0 },
        };
        self.worktrees.put(id_val, wt) catch return error.OutOfMemory;
        return wt.id;
    }

    fn upsertPrFn(p: *anyopaque, _: std.mem.Allocator, repo_id: d.ids.RepoId, snap: d.PrSnapshot, fetched_at: d.Timestamp) d.ports.TaskRepository.Error!d.ids.PrId {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        // Find existing by (repo_id, number)
        var it = self.prs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.repo.id == repo_id and entry.value_ptr.number == snap.number) {
                // Update in place
                entry.value_ptr.url = snap.url;
                entry.value_ptr.title = snap.title;
                entry.value_ptr.head_branch = snap.head_branch;
                entry.value_ptr.state = snap.state;
                entry.value_ptr.updated_at = snap.updated_at;
                entry.value_ptr.fetched_at = fetched_at;
                return entry.value_ptr.id;
            }
        }
        // Insert new
        const id_val = self.next_pr_id;
        self.next_pr_id += 1;
        const pr = d.Pr{
            .id = @enumFromInt(id_val),
            .repo = .{ .id = repo_id, .name = "" },
            .number = snap.number,
            .url = snap.url,
            .title = snap.title,
            .head_branch = snap.head_branch,
            .state = snap.state,
            .updated_at = snap.updated_at,
            .fetched_at = fetched_at,
        };
        self.prs.put(id_val, pr) catch return error.OutOfMemory;
        return pr.id;
    }

    fn upsertIssueFn(p: *anyopaque, _: std.mem.Allocator, provider: d.ids.ProviderId, snap: d.IssueSnapshot, fetched_at: d.Timestamp) d.ports.TaskRepository.Error!d.ids.IssueId {
        const self: *FakeTaskRepo = @ptrCast(@alignCast(p));
        // Find existing by (provider, external_id)
        var it = self.issues.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.provider, provider) and
                std.mem.eql(u8, entry.value_ptr.external_id, snap.external_id))
            {
                // Update in place
                entry.value_ptr.url = snap.url;
                entry.value_ptr.title = snap.title;
                entry.value_ptr.state = snap.state;
                entry.value_ptr.fetched_at = fetched_at;
                return entry.value_ptr.id;
            }
        }
        // Insert new
        const id_val = self.next_iss_id;
        self.next_iss_id += 1;
        const iss = d.Issue{
            .id = @enumFromInt(id_val),
            .provider = provider,
            .external_id = snap.external_id,
            .url = snap.url,
            .title = snap.title,
            .state = snap.state,
            .fetched_at = fetched_at,
        };
        self.issues.put(id_val, iss) catch return error.OutOfMemory;
        return iss.id;
    }
};
