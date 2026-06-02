const std = @import("std");
const d = @import("domain");

pub const FakeWorktreeReader = struct {
    allocator: std.mem.Allocator,
    by_repo: std.StringHashMap([]const d.WorktreeSnapshot),

    pub fn init(a: std.mem.Allocator) FakeWorktreeReader {
        return .{ .allocator = a, .by_repo = std.StringHashMap([]const d.WorktreeSnapshot).init(a) };
    }
    pub fn deinit(self: *FakeWorktreeReader) void {
        self.by_repo.deinit();
    }

    /// Configure what this fake returns for a given repo name.
    pub fn setRepoSnapshots(self: *FakeWorktreeReader, repo_name: []const u8, snaps: []const d.WorktreeSnapshot) !void {
        try self.by_repo.put(repo_name, snaps);
    }

    pub fn interface(self: *FakeWorktreeReader) d.ports.WorktreeReader {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = d.ports.WorktreeReader.VTable{ .list = listFn };

    fn listFn(p: *anyopaque, a: std.mem.Allocator, repo: d.Repo) d.ports.WorktreeReader.Error![]d.WorktreeSnapshot {
        const self: *FakeWorktreeReader = @ptrCast(@alignCast(p));
        const snaps = self.by_repo.get(repo.name) orelse &[_]d.WorktreeSnapshot{};
        const out = a.alloc(d.WorktreeSnapshot, snaps.len) catch return error.OutOfMemory;
        @memcpy(out, snaps);
        return out;
    }
};
