const ids = @import("../value_objects/ids.zig");
const BranchName = @import("../value_objects/branch_name.zig").BranchName;
const Sha = @import("../value_objects/sha.zig").Sha;
const Timestamp = @import("../value_objects/timestamp.zig").Timestamp;
const RepoRef = @import("repo.zig").RepoRef;

pub const Worktree = struct {
    id: ids.WorktreeId,
    repo: RepoRef,
    path: []const u8,
    branch: BranchName,
    head_sha: Sha,
    commits_ahead_of_default: u32,
    has_upstream: bool,
    commits_ahead_of_upstream: ?u32,
    last_seen_at: Timestamp,
};

// Snapshot returned by the WorktreeReader port (no DB id yet)
pub const WorktreeSnapshot = struct {
    path: []const u8,
    branch: BranchName,
    head_sha: Sha,
    commits_ahead_of_default: u32,
    has_upstream: bool,
    commits_ahead_of_upstream: ?u32,
};
