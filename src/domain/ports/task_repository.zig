const std = @import("std");
const d = @import("../root.zig");

pub const TaskRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ NotFound, Conflict, Io, OutOfMemory };

    pub const VTable = struct {
        create: *const fn (*anyopaque, allocator: std.mem.Allocator, d.NewTask) Error!d.Task,
        get:    *const fn (*anyopaque, allocator: std.mem.Allocator, d.ids.TaskId) Error!?d.Task,
        list:   *const fn (*anyopaque, allocator: std.mem.Allocator, d.TaskFilter) Error![]d.Task,
        update: *const fn (*anyopaque, allocator: std.mem.Allocator, d.ids.TaskId, d.TaskPatch) Error!d.Task,
        delete: *const fn (*anyopaque, d.ids.TaskId) Error!void,
        find_by_branch_hint: *const fn (*anyopaque, std.mem.Allocator, d.BranchName) Error!?d.Task,
        find_by_worktree:    *const fn (*anyopaque, std.mem.Allocator, d.ids.WorktreeId) Error!?d.Task,
        upsert_worktree:     *const fn (*anyopaque, std.mem.Allocator, d.ids.RepoId, d.WorktreeSnapshot) Error!d.ids.WorktreeId,
        upsert_pr:           *const fn (*anyopaque, std.mem.Allocator, d.ids.RepoId, d.PrSnapshot, d.Timestamp) Error!d.ids.PrId,
        upsert_issue:        *const fn (*anyopaque, std.mem.Allocator, d.ids.ProviderId, d.IssueSnapshot, d.Timestamp) Error!d.ids.IssueId,
    };

    pub fn create(self: TaskRepository, a: std.mem.Allocator, draft: d.NewTask) Error!d.Task {
        return self.vtable.create(self.ptr, a, draft);
    }
    pub fn get(self: TaskRepository, a: std.mem.Allocator, id: d.ids.TaskId) Error!?d.Task {
        return self.vtable.get(self.ptr, a, id);
    }
    pub fn list(self: TaskRepository, a: std.mem.Allocator, f: d.TaskFilter) Error![]d.Task {
        return self.vtable.list(self.ptr, a, f);
    }
    pub fn update(self: TaskRepository, a: std.mem.Allocator, id: d.ids.TaskId, p: d.TaskPatch) Error!d.Task {
        return self.vtable.update(self.ptr, a, id, p);
    }
    pub fn delete(self: TaskRepository, id: d.ids.TaskId) Error!void {
        return self.vtable.delete(self.ptr, id);
    }
    pub fn findByBranchHint(self: TaskRepository, a: std.mem.Allocator, b: d.BranchName) Error!?d.Task {
        return self.vtable.find_by_branch_hint(self.ptr, a, b);
    }
    pub fn findByWorktree(self: TaskRepository, a: std.mem.Allocator, id: d.ids.WorktreeId) Error!?d.Task {
        return self.vtable.find_by_worktree(self.ptr, a, id);
    }
    pub fn upsertWorktree(self: TaskRepository, a: std.mem.Allocator, repo_id: d.ids.RepoId, snap: d.WorktreeSnapshot) Error!d.ids.WorktreeId {
        return self.vtable.upsert_worktree(self.ptr, a, repo_id, snap);
    }
    pub fn upsertPr(self: TaskRepository, a: std.mem.Allocator, repo_id: d.ids.RepoId, snap: d.PrSnapshot, fetched_at: d.Timestamp) Error!d.ids.PrId {
        return self.vtable.upsert_pr(self.ptr, a, repo_id, snap, fetched_at);
    }
    pub fn upsertIssue(self: TaskRepository, a: std.mem.Allocator, provider: d.ids.ProviderId, snap: d.IssueSnapshot, fetched_at: d.Timestamp) Error!d.ids.IssueId {
        return self.vtable.upsert_issue(self.ptr, a, provider, snap, fetched_at);
    }
};
