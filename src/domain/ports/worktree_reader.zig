const std = @import("std");
const d = @import("../root.zig");

pub const WorktreeReader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ Io, BadFormat, OutOfMemory };

    pub const VTable = struct {
        list: *const fn (*anyopaque, allocator: std.mem.Allocator, d.Repo) Error![]d.WorktreeSnapshot,
    };

    pub fn list(self: WorktreeReader, a: std.mem.Allocator, repo: d.Repo) Error![]d.WorktreeSnapshot {
        return self.vtable.list(self.ptr, a, repo);
    }
};
