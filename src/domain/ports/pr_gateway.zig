const std = @import("std");
const d = @import("../root.zig");

pub const PrGateway = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ Io, BadFormat, AuthFailed, OutOfMemory };

    pub const VTable = struct {
        find_by_branch: *const fn (*anyopaque, allocator: std.mem.Allocator, d.Repo, d.BranchName) Error!?d.PrSnapshot,
    };

    pub fn findByBranch(self: PrGateway, a: std.mem.Allocator, repo: d.Repo, branch: d.BranchName) Error!?d.PrSnapshot {
        return self.vtable.find_by_branch(self.ptr, a, repo, branch);
    }
};
