const std = @import("std");
const d = @import("domain");
const RefreshAll = @import("../use_cases/refresh_all.zig").RefreshAll;
const FakeTaskRepo = @import("fake_task_repo.zig").FakeTaskRepo;
const FakeWorktreeReader = @import("fake_worktree_reader.zig").FakeWorktreeReader;
const FakePrGateway = @import("fake_pr_gateway.zig").FakePrGateway;
const FakeIssueGateway = @import("fake_issue_gateway.zig").FakeIssueGateway;
const FakeClock = @import("fake_clock.zig").FakeClock;

test "Empty repo → no tasks created" {
    const a = std.testing.allocator;
    var repo_fake = FakeTaskRepo.init(a);
    defer repo_fake.deinit();
    var wt_fake = FakeWorktreeReader.init(a);
    defer wt_fake.deinit();
    var pr_fake = FakePrGateway.init(a);
    defer pr_fake.deinit();
    var iss_fake = FakeIssueGateway.init(a, "linear");
    defer iss_fake.deinit();
    var clock_fake = FakeClock.init(.{ .unix_secs = 100 });

    const gateways = [_]d.ports.IssueGateway{iss_fake.interface()};
    const uc = RefreshAll{
        .tasks = repo_fake.interface(),
        .worktrees = wt_fake.interface(),
        .prs = pr_fake.interface(),
        .issues = &gateways,
        .clock = clock_fake.interface(),
        .patterns = &.{},
    };

    var report = try uc.execute(a, &.{});
    defer report.deinit(a);

    try std.testing.expectEqual(@as(u32, 0), report.tasks_created);
    try std.testing.expectEqual(@as(usize, 0), report.errors.items.len);
}

test "One worktree creates a task with in_progress status" {
    const a = std.testing.allocator;
    var repo_fake = FakeTaskRepo.init(a);
    defer repo_fake.deinit();
    var wt_fake = FakeWorktreeReader.init(a);
    defer wt_fake.deinit();
    var pr_fake = FakePrGateway.init(a);
    defer pr_fake.deinit();
    var iss_fake = FakeIssueGateway.init(a, "linear");
    defer iss_fake.deinit();
    var clock_fake = FakeClock.init(.{ .unix_secs = 100 });

    const snaps = [_]d.WorktreeSnapshot{.{
        .path = "/x",
        .branch = .{ .value = "feat/foo" },
        .head_sha = .{ .value = "abc" },
        .commits_ahead_of_default = 1,
        .has_upstream = false,
        .commits_ahead_of_upstream = null,
    }};
    try wt_fake.setRepoSnapshots("r", &snaps);

    const repos = [_]d.Repo{.{
        .id = @enumFromInt(1),
        .name = "r",
        .root_path = "/r",
        .github = null,
        .default_branch = "main",
    }};
    const gateways = [_]d.ports.IssueGateway{iss_fake.interface()};
    const uc = RefreshAll{
        .tasks = repo_fake.interface(),
        .worktrees = wt_fake.interface(),
        .prs = pr_fake.interface(),
        .issues = &gateways,
        .clock = clock_fake.interface(),
        .patterns = &.{},
    };

    var report = try uc.execute(a, &repos);
    defer report.deinit(a);

    try std.testing.expectEqual(@as(u32, 1), report.tasks_created);
    const tasks = try repo_fake.interface().list(a, .{});
    defer a.free(tasks);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expect(tasks[0].worktree != null);
    try std.testing.expectEqual(d.Status.in_progress, d.derive_status(tasks[0]));
}

test "Pre-existing Todo with matching branch_hint becomes in_progress" {
    const a = std.testing.allocator;
    var repo_fake = FakeTaskRepo.init(a);
    defer repo_fake.deinit();
    var wt_fake = FakeWorktreeReader.init(a);
    defer wt_fake.deinit();
    var pr_fake = FakePrGateway.init(a);
    defer pr_fake.deinit();
    var iss_fake = FakeIssueGateway.init(a, "linear");
    defer iss_fake.deinit();
    var clock_fake = FakeClock.init(.{ .unix_secs = 100 });

    // Pre-create a todo task with matching branch_hint
    const existing = try repo_fake.interface().create(a, .{
        .title = "Implement foo feature",
        .branch_hint = .{ .value = "feat/foo" },
    });

    const snaps = [_]d.WorktreeSnapshot{.{
        .path = "/x",
        .branch = .{ .value = "feat/foo" },
        .head_sha = .{ .value = "abc" },
        .commits_ahead_of_default = 1,
        .has_upstream = false,
        .commits_ahead_of_upstream = null,
    }};
    try wt_fake.setRepoSnapshots("r", &snaps);

    const repos = [_]d.Repo{.{
        .id = @enumFromInt(1),
        .name = "r",
        .root_path = "/r",
        .github = null,
        .default_branch = "main",
    }};
    const gateways = [_]d.ports.IssueGateway{iss_fake.interface()};
    const uc = RefreshAll{
        .tasks = repo_fake.interface(),
        .worktrees = wt_fake.interface(),
        .prs = pr_fake.interface(),
        .issues = &gateways,
        .clock = clock_fake.interface(),
        .patterns = &.{},
    };

    var report = try uc.execute(a, &repos);
    defer report.deinit(a);

    // No new task created — existing one was linked
    try std.testing.expectEqual(@as(u32, 0), report.tasks_created);

    const tasks = try repo_fake.interface().list(a, .{});
    defer a.free(tasks);
    // Still only one task
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    // It should be the same task (same id)
    try std.testing.expectEqual(existing.id, tasks[0].id);
    // Now linked to a worktree → in_progress
    try std.testing.expect(tasks[0].worktree != null);
    try std.testing.expectEqual(d.Status.in_progress, d.derive_status(tasks[0]));
}

test "Worktree + open PR → task in_review" {
    const a = std.testing.allocator;
    var repo_fake = FakeTaskRepo.init(a);
    defer repo_fake.deinit();
    var wt_fake = FakeWorktreeReader.init(a);
    defer wt_fake.deinit();
    var pr_fake = FakePrGateway.init(a);
    defer pr_fake.deinit();
    var iss_fake = FakeIssueGateway.init(a, "linear");
    defer iss_fake.deinit();
    var clock_fake = FakeClock.init(.{ .unix_secs = 100 });

    const snaps = [_]d.WorktreeSnapshot{.{
        .path = "/x",
        .branch = .{ .value = "feat/foo" },
        .head_sha = .{ .value = "abc" },
        .commits_ahead_of_default = 2,
        .has_upstream = true,
        .commits_ahead_of_upstream = 1,
    }};
    try wt_fake.setRepoSnapshots("r", &snaps);

    try pr_fake.setPr("feat/foo", .{
        .number = 42,
        .url = .{ .value = "https://github.com/r/pull/42" },
        .title = "Implement foo",
        .head_branch = .{ .value = "feat/foo" },
        .state = .open,
        .updated_at = .{ .unix_secs = 99 },
    });

    const repos = [_]d.Repo{.{
        .id = @enumFromInt(1),
        .name = "r",
        .root_path = "/r",
        .github = null,
        .default_branch = "main",
    }};
    const gateways = [_]d.ports.IssueGateway{iss_fake.interface()};
    const uc = RefreshAll{
        .tasks = repo_fake.interface(),
        .worktrees = wt_fake.interface(),
        .prs = pr_fake.interface(),
        .issues = &gateways,
        .clock = clock_fake.interface(),
        .patterns = &.{},
    };

    var report = try uc.execute(a, &repos);
    defer report.deinit(a);

    try std.testing.expectEqual(@as(u32, 1), report.tasks_created);
    try std.testing.expectEqual(@as(u32, 1), report.prs_updated);

    const tasks = try repo_fake.interface().list(a, .{});
    defer a.free(tasks);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expect(tasks[0].pr != null);
    try std.testing.expectEqual(d.Status.in_review, d.derive_status(tasks[0]));
}

test "Ticket parsing creates issue link when issue gateway has the issue" {
    const a = std.testing.allocator;
    var repo_fake = FakeTaskRepo.init(a);
    defer repo_fake.deinit();
    var wt_fake = FakeWorktreeReader.init(a);
    defer wt_fake.deinit();
    var pr_fake = FakePrGateway.init(a);
    defer pr_fake.deinit();
    var iss_fake = FakeIssueGateway.init(a, "linear");
    defer iss_fake.deinit();
    var clock_fake = FakeClock.init(.{ .unix_secs = 100 });

    const snaps = [_]d.WorktreeSnapshot{.{
        .path = "/x",
        .branch = .{ .value = "moe-272-implement-auth" },
        .head_sha = .{ .value = "def" },
        .commits_ahead_of_default = 1,
        .has_upstream = false,
        .commits_ahead_of_upstream = null,
    }};
    try wt_fake.setRepoSnapshots("r", &snaps);

    try iss_fake.setIssue("MOE-272", .{
        .external_id = "MOE-272",
        .url = "https://linear.app/team/issue/MOE-272",
        .title = "Implement auth",
        .state = "In Progress",
    });

    const repos = [_]d.Repo{.{
        .id = @enumFromInt(1),
        .name = "r",
        .root_path = "/r",
        .github = null,
        .default_branch = "main",
    }};
    const patterns = [_]d.ticket.ProviderPattern{.{ .provider = "linear" }};
    const gateways = [_]d.ports.IssueGateway{iss_fake.interface()};
    const uc = RefreshAll{
        .tasks = repo_fake.interface(),
        .worktrees = wt_fake.interface(),
        .prs = pr_fake.interface(),
        .issues = &gateways,
        .clock = clock_fake.interface(),
        .patterns = &patterns,
    };

    var report = try uc.execute(a, &repos);
    defer report.deinit(a);

    try std.testing.expectEqual(@as(u32, 1), report.tasks_created);
    try std.testing.expectEqual(@as(u32, 1), report.issues_updated);

    const tasks = try repo_fake.interface().list(a, .{});
    defer a.free(tasks);
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    try std.testing.expect(tasks[0].issue != null);
    try std.testing.expectEqualStrings("MOE-272", tasks[0].issue.?.external_id);
}
