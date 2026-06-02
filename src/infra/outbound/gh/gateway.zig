const std = @import("std");
const d = @import("domain");

// ─── JSON parser ─────────────────────────────────────────────────────────────

pub fn parseGhJson(a: std.mem.Allocator, json: []const u8) !?d.PrSnapshot {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    if (arr.items.len == 0) return null;
    const obj = arr.items[0].object;

    const state_raw = obj.get("state").?.string;
    const is_draft = obj.get("isDraft").?.bool;
    const state: d.PrState =
        if (std.mem.eql(u8, state_raw, "MERGED")) .merged
        else if (std.mem.eql(u8, state_raw, "CLOSED")) .closed
        else if (is_draft) .draft
        else .open;

    const url_str = try a.dupe(u8, obj.get("url").?.string);
    errdefer a.free(url_str);
    const title_str = try a.dupe(u8, obj.get("title").?.string);
    errdefer a.free(title_str);
    const branch_str = try a.dupe(u8, obj.get("headRefName").?.string);
    errdefer a.free(branch_str);

    return d.PrSnapshot{
        .number = @intCast(obj.get("number").?.integer),
        .url = .{ .value = url_str },
        .title = title_str,
        .head_branch = .{ .value = branch_str },
        .state = state,
        .updated_at = .{ .unix_secs = 0 }, // ISO8601 parsing deferred to v1.1
    };
}

// ─── GhPrGateway adapter ─────────────────────────────────────────────────────

pub const GhPrGateway = struct {
    io: std.Io,

    pub fn init(io: std.Io) GhPrGateway {
        return .{ .io = io };
    }

    pub fn interface(self: *GhPrGateway) d.ports.PrGateway {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = d.ports.PrGateway.VTable{ .find_by_branch = findFn };

    fn findFn(p: *anyopaque, a: std.mem.Allocator, repo: d.Repo, branch: d.BranchName) d.ports.PrGateway.Error!?d.PrSnapshot {
        const self: *GhPrGateway = @ptrCast(@alignCast(p));

        if (repo.github == null) return null;
        const owner_repo = repo.github.?;

        const args = [_][]const u8{
            "gh",        "pr",       "list",
            "--repo",    owner_repo, "--head",
            branch.value,
            "--state",   "all",
            "--json",    "number,url,title,headRefName,state,isDraft,updatedAt",
            "--limit",   "1",
        };

        const result = std.process.run(a, self.io, .{ .argv = &args }) catch return error.Io;
        defer a.free(result.stderr);
        errdefer a.free(result.stdout);

        switch (result.term) {
            .exited => |code| if (code != 0) return error.Io,
            else => return error.Io,
        }

        const parsed = parseGhJson(a, result.stdout) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadFormat,
        };
        a.free(result.stdout); // success path: errdefer won't fire, free explicitly
        return parsed;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "parses open PR" {
    const j = "[{\"number\":141,\"url\":\"https://x\",\"title\":\"t\",\"headRefName\":\"feat/x\",\"state\":\"OPEN\",\"isDraft\":false,\"updatedAt\":\"2026-06-01T00:00:00Z\"}]";
    const got = (try parseGhJson(std.testing.allocator, j)).?;
    defer std.testing.allocator.free(got.url.value);
    defer std.testing.allocator.free(got.title);
    defer std.testing.allocator.free(got.head_branch.value);
    try std.testing.expectEqual(d.PrState.open, got.state);
    try std.testing.expectEqual(@as(u32, 141), got.number);
}

test "draft PR maps to draft state" {
    const j = "[{\"number\":1,\"url\":\"\",\"title\":\"\",\"headRefName\":\"\",\"state\":\"OPEN\",\"isDraft\":true,\"updatedAt\":\"\"}]";
    const got = (try parseGhJson(std.testing.allocator, j)).?;
    defer std.testing.allocator.free(got.url.value);
    defer std.testing.allocator.free(got.title);
    defer std.testing.allocator.free(got.head_branch.value);
    try std.testing.expectEqual(d.PrState.draft, got.state);
}

test "merged PR maps to merged state" {
    const j = "[{\"number\":1,\"url\":\"\",\"title\":\"\",\"headRefName\":\"\",\"state\":\"MERGED\",\"isDraft\":false,\"updatedAt\":\"\"}]";
    const got = (try parseGhJson(std.testing.allocator, j)).?;
    defer std.testing.allocator.free(got.url.value);
    defer std.testing.allocator.free(got.title);
    defer std.testing.allocator.free(got.head_branch.value);
    try std.testing.expectEqual(d.PrState.merged, got.state);
}

test "closed PR maps to closed state" {
    const j = "[{\"number\":1,\"url\":\"\",\"title\":\"\",\"headRefName\":\"\",\"state\":\"CLOSED\",\"isDraft\":false,\"updatedAt\":\"\"}]";
    const got = (try parseGhJson(std.testing.allocator, j)).?;
    defer std.testing.allocator.free(got.url.value);
    defer std.testing.allocator.free(got.title);
    defer std.testing.allocator.free(got.head_branch.value);
    try std.testing.expectEqual(d.PrState.closed, got.state);
}

test "empty array returns null" {
    const got = try parseGhJson(std.testing.allocator, "[]");
    try std.testing.expectEqual(@as(?d.PrSnapshot, null), got);
}
