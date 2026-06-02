const std = @import("std");
const d = @import("domain");

pub const LinkTarget = union(enum) {
    worktree: d.ids.WorktreeId,
    pr: d.ids.PrId,
    issue: d.ids.IssueId,
    clear_worktree,
    clear_pr,
    clear_issue,
};

pub const LinkTask = struct {
    tasks: d.ports.TaskRepository,
    pub fn execute(self: LinkTask, a: std.mem.Allocator, id: d.ids.TaskId, target: LinkTarget) !d.Task {
        var patch = d.TaskPatch{};
        switch (target) {
            .worktree => |w| patch.worktree_id = @as(?d.ids.WorktreeId, w),
            .pr       => |p| patch.pr_id       = @as(?d.ids.PrId, p),
            .issue    => |i| patch.issue_id    = @as(?d.ids.IssueId, i),
            .clear_worktree => patch.worktree_id = @as(?d.ids.WorktreeId, null),
            .clear_pr       => patch.pr_id       = @as(?d.ids.PrId, null),
            .clear_issue    => patch.issue_id    = @as(?d.ids.IssueId, null),
        }
        return self.tasks.update(a, id, patch);
    }
};
