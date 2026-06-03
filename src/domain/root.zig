pub const ids          = @import("value_objects/ids.zig");
pub const BranchName   = @import("value_objects/branch_name.zig").BranchName;
pub const Sha          = @import("value_objects/sha.zig").Sha;
pub const Timestamp    = @import("value_objects/timestamp.zig").Timestamp;
pub const Url          = @import("value_objects/url.zig").Url;
pub const SessionHandle = @import("value_objects/session_handle.zig").SessionHandle;

pub const status    = @import("entities/status.zig");
pub const Status    = status.Status;
pub const PrState   = status.PrState;

pub const Repo               = @import("entities/repo.zig").Repo;
pub const RepoRef            = @import("entities/repo.zig").RepoRef;
pub const Worktree           = @import("entities/worktree.zig").Worktree;
pub const WorktreeSnapshot   = @import("entities/worktree.zig").WorktreeSnapshot;
pub const Pr                 = @import("entities/pr.zig").Pr;
pub const PrSnapshot         = @import("entities/pr.zig").PrSnapshot;
pub const Issue              = @import("entities/issue.zig").Issue;
pub const IssueSnapshot      = @import("entities/issue.zig").IssueSnapshot;
pub const Task               = @import("entities/task.zig").Task;
pub const NewTask            = @import("entities/task.zig").NewTask;
pub const TaskPatch          = @import("entities/task.zig").TaskPatch;
pub const TaskFilter         = @import("entities/task.zig").TaskFilter;
pub const HandoffEntry       = @import("entities/handoff.zig").HandoffEntry;
pub const NewHandoff         = @import("entities/handoff.zig").NewHandoff;

pub const derive_status = @import("services/status_derive.zig").derive;
pub const ticket = @import("services/ticket_parse.zig");
pub const hints = @import("services/hints.zig");

pub const ports = struct {
    pub const TaskRepository = @import("ports/task_repository.zig").TaskRepository;
    pub const WorktreeReader = @import("ports/worktree_reader.zig").WorktreeReader;
    pub const PrGateway      = @import("ports/pr_gateway.zig").PrGateway;
    pub const IssueGateway   = @import("ports/issue_gateway.zig").IssueGateway;
    pub const Clock          = @import("ports/clock.zig").Clock;
};

test { _ = @import("entities/task.zig"); _ = @import("entities/handoff.zig"); _ = @import("services/status_derive.zig"); _ = @import("services/ticket_parse.zig"); _ = @import("services/hints.zig"); _ = @import("value_objects/session_handle.zig"); }

test "Clock vtable round-trip" {
    const std = @import("std");
    const TS = @import("value_objects/timestamp.zig").Timestamp;
    const Clock = ports.Clock;
    const Fake = struct {
        value: TS,
        fn nowFn(p: *anyopaque) TS {
            const self: *@This() = @ptrCast(@alignCast(p));
            return self.value;
        }
        const vt = Clock.VTable{ .now = nowFn };
    };
    var f = Fake{ .value = .{ .unix_secs = 42 } };
    const c = Clock{ .ptr = &f, .vtable = &Fake.vt };
    try std.testing.expectEqual(@as(i64, 42), c.now().unix_secs);
}
