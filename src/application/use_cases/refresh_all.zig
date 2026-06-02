const std = @import("std");
const d = @import("domain");

pub const RefreshReport = struct {
    tasks_created: u32 = 0,
    prs_updated: u32 = 0,
    issues_updated: u32 = 0,
    errors: std.ArrayList([]const u8),

    pub fn deinit(self: *RefreshReport, a: std.mem.Allocator) void {
        for (self.errors.items) |e| a.free(e);
        self.errors.deinit(a);
    }
};

pub const RefreshAll = struct {
    tasks: d.ports.TaskRepository,
    worktrees: d.ports.WorktreeReader,
    prs: d.ports.PrGateway,
    issues: []const d.ports.IssueGateway,
    clock: d.ports.Clock,
    patterns: []const d.ticket.ProviderPattern,

    pub fn execute(self: RefreshAll, a: std.mem.Allocator, repos: []const d.Repo) !RefreshReport {
        var report = RefreshReport{ .errors = .empty };

        for (repos) |repo| {
            const snaps = self.worktrees.list(a, repo) catch |err| {
                const msg = std.fmt.allocPrint(a, "worktrees.list({s}) failed: {s}", .{ repo.name, @errorName(err) }) catch continue;
                report.errors.append(a, msg) catch a.free(msg);
                continue;
            };
            defer a.free(snaps);

            for (snaps) |snap| {
                const task = self.ensureTaskForWorktree(a, repo, snap, &report) catch |err| {
                    const msg = std.fmt.allocPrint(a, "ensureTaskForWorktree failed: {s}", .{@errorName(err)}) catch continue;
                    report.errors.append(a, msg) catch a.free(msg);
                    continue;
                };

                // PR lookup
                if (self.prs.findByBranch(a, repo, snap.branch)) |maybe_pr| {
                    if (maybe_pr) |pr_snap| {
                        const pr_id = self.tasks.upsertPr(a, repo.id, pr_snap, self.clock.now()) catch null;
                        if (pr_id) |pid| {
                            _ = self.tasks.update(a, task.id, .{ .pr_id = @as(?d.ids.PrId, pid) }) catch {};
                            report.prs_updated += 1;
                        }
                    }
                } else |err| {
                    const msg = std.fmt.allocPrint(a, "gh PR lookup for {s} failed: {s}", .{ snap.branch.value, @errorName(err) }) catch continue;
                    report.errors.append(a, msg) catch a.free(msg);
                }

                // Issue lookup (only if task has no issue link yet)
                if (task.issue == null) {
                    const maybe_ref = d.ticket.parse(a, snap.branch, self.patterns) catch null;
                    if (maybe_ref) |ref| {
                        defer a.free(ref.external_id);
                        for (self.issues) |gw| {
                            if (!std.mem.eql(u8, gw.providerId(), ref.provider)) continue;
                            if (gw.fetch(a, ref.external_id)) |maybe_iss| {
                                if (maybe_iss) |iss_snap| {
                                    const iss_id = self.tasks.upsertIssue(a, ref.provider, iss_snap, self.clock.now()) catch null;
                                    if (iss_id) |iid| {
                                        _ = self.tasks.update(a, task.id, .{ .issue_id = @as(?d.ids.IssueId, iid) }) catch {};
                                        report.issues_updated += 1;
                                    }
                                }
                            } else |err| {
                                const msg = std.fmt.allocPrint(a, "{s} issue fetch failed: {s}", .{ ref.provider, @errorName(err) }) catch continue;
                                report.errors.append(a, msg) catch a.free(msg);
                            }
                            break;
                        }
                    }
                }
            }
        }
        return report;
    }

    fn ensureTaskForWorktree(self: RefreshAll, a: std.mem.Allocator, repo: d.Repo, snap: d.WorktreeSnapshot, report: *RefreshReport) !d.Task {
        const wt_id = try self.tasks.upsertWorktree(a, repo.id, snap);

        // Already linked?
        if (try self.tasks.findByWorktree(a, wt_id)) |t| return t;

        // Pending todo with matching branch_hint?
        if (try self.tasks.findByBranchHint(a, snap.branch)) |t| {
            return try self.tasks.update(a, t.id, .{ .worktree_id = @as(?d.ids.WorktreeId, wt_id) });
        }

        // Otherwise create a fresh task titled after the branch
        const created = try self.tasks.create(a, .{
            .title = snap.branch.value,
            .branch_hint = snap.branch,
        });
        report.tasks_created += 1;
        return try self.tasks.update(a, created.id, .{ .worktree_id = @as(?d.ids.WorktreeId, wt_id) });
    }
};
