const std = @import("std");
const Task = @import("../entities/task.zig").Task;
const Pr = @import("../entities/pr.zig").Pr;
const status = @import("../entities/status.zig");
const Status = status.Status;
const PrState = status.PrState;

pub fn derive(task: Task) Status {
    if (task.archived) return .archived;
    if (task.pr) |pr| return switch (pr.state) {
        .merged, .closed => .done,
        .open, .draft    => .in_review,
    };
    return if (task.worktree != null) .in_progress else .todo;
}

// === tests ===

const test_helpers = struct {
    fn baseTask() Task {
        return Task{
            .id = @enumFromInt(1),
            .title = "t",
            .branch_hint = null,
            .worktree = null,
            .pr = null,
            .issue = null,
            .archived = false,
            .notes = null,
            .session = null,
            .project_path = null,
            .created_at = .{ .unix_secs = 0 },
            .updated_at = .{ .unix_secs = 0 },
        };
    }

    fn prWithState(state: PrState) Pr {
        return Pr{
            .id = @enumFromInt(1),
            .repo = .{ .id = @enumFromInt(1), .name = "r" },
            .number = 1,
            .url = .{ .value = "" },
            .title = "",
            .head_branch = .{ .value = "" },
            .state = state,
            .updated_at = .{ .unix_secs = 0 },
            .fetched_at = .{ .unix_secs = 0 },
        };
    }
};

test "no worktree no pr → todo" {
    try std.testing.expectEqual(Status.todo, derive(test_helpers.baseTask()));
}

test "archived → archived (even with PR)" {
    var t = test_helpers.baseTask();
    t.archived = true;
    t.pr = test_helpers.prWithState(.open);
    try std.testing.expectEqual(Status.archived, derive(t));
}

test "open PR → in_review" {
    var t = test_helpers.baseTask();
    t.pr = test_helpers.prWithState(.open);
    try std.testing.expectEqual(Status.in_review, derive(t));
}

test "draft PR → in_review" {
    var t = test_helpers.baseTask();
    t.pr = test_helpers.prWithState(.draft);
    try std.testing.expectEqual(Status.in_review, derive(t));
}

test "merged PR → done" {
    var t = test_helpers.baseTask();
    t.pr = test_helpers.prWithState(.merged);
    try std.testing.expectEqual(Status.done, derive(t));
}

test "closed PR → done" {
    var t = test_helpers.baseTask();
    t.pr = test_helpers.prWithState(.closed);
    try std.testing.expectEqual(Status.done, derive(t));
}

test "worktree but no PR → in_progress" {
    var t = test_helpers.baseTask();
    t.worktree = .{
        .id = @enumFromInt(1),
        .repo = .{ .id = @enumFromInt(1), .name = "r" },
        .path = "/x",
        .branch = .{ .value = "b" },
        .head_sha = .{ .value = "" },
        .commits_ahead_of_default = 0,
        .has_upstream = false,
        .commits_ahead_of_upstream = null,
        .last_seen_at = .{ .unix_secs = 0 },
    };
    try std.testing.expectEqual(Status.in_progress, derive(t));
}
