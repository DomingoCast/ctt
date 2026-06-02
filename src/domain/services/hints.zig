const std = @import("std");
const Worktree = @import("../entities/worktree.zig").Worktree;
const Pr = @import("../entities/pr.zig").Pr;

pub const InProgressHint = union(enum) {
    no_commits,
    n_commits_ahead_not_pushed: u32,
    pushed_no_pr,
    n_unpushed_commits: u32,
};

pub fn inProgress(wt: Worktree, pr: ?Pr) InProgressHint {
    _ = pr;  // hint logic itself doesn't need pr for in_progress (caller knows pr is null)
    if (wt.commits_ahead_of_default == 0) return .no_commits;
    if (!wt.has_upstream) return .{ .n_commits_ahead_not_pushed = wt.commits_ahead_of_default };
    const ahead_up = wt.commits_ahead_of_upstream orelse 0;
    if (ahead_up == 0) return .pushed_no_pr;
    return .{ .n_unpushed_commits = ahead_up };
}

const test_helpers = struct {
    fn wt(commits_ahead: u32, has_up: bool, ahead_of_up: ?u32) Worktree {
        return .{
            .id = @enumFromInt(1),
            .repo = .{ .id = @enumFromInt(1), .name = "r" },
            .path = "/x",
            .branch = .{ .value = "b" },
            .head_sha = .{ .value = "" },
            .commits_ahead_of_default = commits_ahead,
            .has_upstream = has_up,
            .commits_ahead_of_upstream = ahead_of_up,
            .last_seen_at = .{ .unix_secs = 0 },
        };
    }
};

test "no commits ahead → no_commits" {
    const got = inProgress(test_helpers.wt(0, false, null), null);
    try std.testing.expect(got == .no_commits);
}

test "commits ahead, no upstream → n_commits_ahead_not_pushed" {
    const got = inProgress(test_helpers.wt(3, false, null), null);
    try std.testing.expect(got == .n_commits_ahead_not_pushed and got.n_commits_ahead_not_pushed == 3);
}

test "pushed, no PR → pushed_no_pr" {
    const got = inProgress(test_helpers.wt(3, true, 0), null);
    try std.testing.expect(got == .pushed_no_pr);
}

test "has upstream, unpushed commits → n_unpushed_commits" {
    const got = inProgress(test_helpers.wt(5, true, 2), null);
    try std.testing.expect(got == .n_unpushed_commits and got.n_unpushed_commits == 2);
}
