const std = @import("std");
const ids = @import("../value_objects/ids.zig");
const Timestamp = @import("../value_objects/timestamp.zig").Timestamp;
const handoff = @import("../entities/handoff.zig");

pub const HandoffRepository = struct {
    pub const Error = error{
        Io,
        OutOfMemory,
        NotFound,
    };

    pub const VTable = struct {
        append: *const fn (ptr: *anyopaque, a: std.mem.Allocator, draft: handoff.NewHandoff, now: Timestamp) Error!ids.HandoffId,
        list:   *const fn (ptr: *anyopaque, a: std.mem.Allocator, task_id: ids.TaskId, limit: ?usize) Error![]handoff.HandoffEntry,
        latest: *const fn (ptr: *anyopaque, a: std.mem.Allocator, task_id: ids.TaskId) Error!?handoff.HandoffEntry,
    };

    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn append(self: HandoffRepository, a: std.mem.Allocator, draft: handoff.NewHandoff, now: Timestamp) Error!ids.HandoffId {
        return self.vtable.append(self.ptr, a, draft, now);
    }
    pub fn list(self: HandoffRepository, a: std.mem.Allocator, task_id: ids.TaskId, limit: ?usize) Error![]handoff.HandoffEntry {
        return self.vtable.list(self.ptr, a, task_id, limit);
    }
    pub fn latest(self: HandoffRepository, a: std.mem.Allocator, task_id: ids.TaskId) Error!?handoff.HandoffEntry {
        return self.vtable.latest(self.ptr, a, task_id);
    }
};
