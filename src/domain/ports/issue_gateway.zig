const std = @import("std");
const d = @import("../root.zig");

pub const IssueGateway = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ Io, BadFormat, AuthFailed, NotConfigured, OutOfMemory };

    pub const VTable = struct {
        provider_id: *const fn (*anyopaque) d.ids.ProviderId,
        fetch: *const fn (*anyopaque, allocator: std.mem.Allocator, []const u8) Error!?d.IssueSnapshot,
    };

    pub fn providerId(self: IssueGateway) d.ids.ProviderId {
        return self.vtable.provider_id(self.ptr);
    }
    pub fn fetch(self: IssueGateway, a: std.mem.Allocator, external_id: []const u8) Error!?d.IssueSnapshot {
        return self.vtable.fetch(self.ptr, a, external_id);
    }
};
