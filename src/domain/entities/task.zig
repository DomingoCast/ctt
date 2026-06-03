const ids = @import("../value_objects/ids.zig");
const BranchName = @import("../value_objects/branch_name.zig").BranchName;
const Timestamp = @import("../value_objects/timestamp.zig").Timestamp;
const Worktree = @import("worktree.zig").Worktree;
const Pr = @import("pr.zig").Pr;
const Issue = @import("issue.zig").Issue;

pub const Task = struct {
    id: ids.TaskId,
    title: []const u8,
    branch_hint: ?BranchName,
    worktree: ?Worktree,
    pr: ?Pr,
    issue: ?Issue,
    archived: bool,
    notes: ?[]const u8,
    session: ?@import("../value_objects/session_handle.zig").SessionHandle,
    created_at: Timestamp,
    updated_at: Timestamp,
};

pub const NewTask = struct {
    title: []const u8,
    branch_hint: ?BranchName = null,
    notes: ?[]const u8 = null,
};

pub const TaskPatch = struct {
    title: ?[]const u8 = null,
    branch_hint: ?BranchName = null,
    notes: ?[]const u8 = null,
    archived: ?bool = null,
    worktree_id: ??ids.WorktreeId = null,   // ??: outer null = no change, Some(null) = clear, Some(x) = set
    pr_id: ??ids.PrId = null,
    issue_id: ??ids.IssueId = null,
    session: ??@import("../value_objects/session_handle.zig").SessionHandle = null,
    // outer null = no change; Some(null) = clear; Some(x) = set
};

pub const TaskFilter = struct {
    status: ?@import("status.zig").Status = null,
    repo_name: ?[]const u8 = null,
    text: ?[]const u8 = null,
};
