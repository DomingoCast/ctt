const std = @import("std");
const d = @import("domain");

pub const FakeIssueGateway = struct {
    provider: []const u8,
    by_id: std.StringHashMap(d.IssueSnapshot),
    allocator: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator, provider: []const u8) FakeIssueGateway {
        return .{
            .provider = provider,
            .allocator = a,
            .by_id = std.StringHashMap(d.IssueSnapshot).init(a),
        };
    }
    pub fn deinit(self: *FakeIssueGateway) void {
        self.by_id.deinit();
    }

    pub fn setIssue(self: *FakeIssueGateway, id: []const u8, iss: d.IssueSnapshot) !void {
        try self.by_id.put(id, iss);
    }

    pub fn interface(self: *FakeIssueGateway) d.ports.IssueGateway {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt = d.ports.IssueGateway.VTable{ .provider_id = providerIdFn, .fetch = fetchFn };

    fn providerIdFn(p: *anyopaque) d.ids.ProviderId {
        const self: *FakeIssueGateway = @ptrCast(@alignCast(p));
        return self.provider;
    }
    fn fetchFn(p: *anyopaque, _: std.mem.Allocator, external_id: []const u8) d.ports.IssueGateway.Error!?d.IssueSnapshot {
        const self: *FakeIssueGateway = @ptrCast(@alignCast(p));
        return self.by_id.get(external_id);
    }
};
