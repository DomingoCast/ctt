const std = @import("std");
const d = @import("domain");

pub const FakePrGateway = struct {
    by_branch: std.StringHashMap(d.PrSnapshot),
    allocator: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) FakePrGateway {
        return .{ .allocator = a, .by_branch = std.StringHashMap(d.PrSnapshot).init(a) };
    }
    pub fn deinit(self: *FakePrGateway) void {
        self.by_branch.deinit();
    }

    pub fn setPr(self: *FakePrGateway, branch: []const u8, pr: d.PrSnapshot) !void {
        try self.by_branch.put(branch, pr);
    }

    pub fn interface(self: *FakePrGateway) d.ports.PrGateway {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt = d.ports.PrGateway.VTable{ .find_by_branch = findFn };

    fn findFn(p: *anyopaque, _: std.mem.Allocator, _: d.Repo, branch: d.BranchName) d.ports.PrGateway.Error!?d.PrSnapshot {
        const self: *FakePrGateway = @ptrCast(@alignCast(p));
        return self.by_branch.get(branch.value);
    }
};
