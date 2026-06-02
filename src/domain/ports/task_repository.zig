const std = @import("std");
const d = @import("../root.zig");

pub const TaskRepository = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{ NotFound, Conflict, Io, OutOfMemory };

    pub const VTable = struct {
        create: *const fn (*anyopaque, allocator: std.mem.Allocator, d.NewTask) Error!d.Task,
        get:    *const fn (*anyopaque, allocator: std.mem.Allocator, d.ids.TaskId) Error!?d.Task,
        list:   *const fn (*anyopaque, allocator: std.mem.Allocator, d.TaskFilter) Error![]d.Task,
        update: *const fn (*anyopaque, allocator: std.mem.Allocator, d.ids.TaskId, d.TaskPatch) Error!d.Task,
        delete: *const fn (*anyopaque, d.ids.TaskId) Error!void,
    };

    pub fn create(self: TaskRepository, a: std.mem.Allocator, draft: d.NewTask) Error!d.Task {
        return self.vtable.create(self.ptr, a, draft);
    }
    pub fn get(self: TaskRepository, a: std.mem.Allocator, id: d.ids.TaskId) Error!?d.Task {
        return self.vtable.get(self.ptr, a, id);
    }
    pub fn list(self: TaskRepository, a: std.mem.Allocator, f: d.TaskFilter) Error![]d.Task {
        return self.vtable.list(self.ptr, a, f);
    }
    pub fn update(self: TaskRepository, a: std.mem.Allocator, id: d.ids.TaskId, p: d.TaskPatch) Error!d.Task {
        return self.vtable.update(self.ptr, a, id, p);
    }
    pub fn delete(self: TaskRepository, id: d.ids.TaskId) Error!void {
        return self.vtable.delete(self.ptr, id);
    }
};
