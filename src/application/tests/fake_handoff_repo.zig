const std = @import("std");
const d = @import("domain");

/// In-memory HandoffRepository test double.
/// Uses an internal arena so all string allocations are freed on deinit().
pub const FakeHandoffRepo = struct {
    backing: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    next_id: i64,
    entries: std.ArrayList(d.HandoffEntry),

    pub fn init(a: std.mem.Allocator) FakeHandoffRepo {
        return .{
            .backing = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .next_id = 1,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *FakeHandoffRepo) void {
        self.entries.deinit(self.backing);
        self.arena.deinit();
    }

    pub fn interface(self: *FakeHandoffRepo) d.ports.HandoffRepository {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = d.ports.HandoffRepository.VTable{
        .append = appendFn,
        .list   = listFn,
        .latest = latestFn,
    };

    fn appendFn(p: *anyopaque, _: std.mem.Allocator, draft: d.NewHandoff, now: d.Timestamp) d.ports.HandoffRepository.Error!d.ids.HandoffId {
        const self: *FakeHandoffRepo = @ptrCast(@alignCast(p));
        const aa = self.arena.allocator();
        const id_val = self.next_id;
        self.next_id += 1;
        const entry = d.HandoffEntry{
            .id = @enumFromInt(id_val),
            .task_id = draft.task_id,
            .body = aa.dupe(u8, draft.body) catch return error.OutOfMemory,
            .created_at = now,
        };
        self.entries.append(self.backing, entry) catch return error.OutOfMemory;
        return entry.id;
    }

    fn listFn(p: *anyopaque, a: std.mem.Allocator, task_id: d.ids.TaskId, limit: ?usize) d.ports.HandoffRepository.Error![]d.HandoffEntry {
        const self: *FakeHandoffRepo = @ptrCast(@alignCast(p));
        var out: std.ArrayList(d.HandoffEntry) = .empty;
        errdefer {
            for (out.items) |e| a.free(e.body);
            out.deinit(a);
        }
        // newest first (reverse order)
        var i = self.entries.items.len;
        var count: usize = 0;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (e.task_id != task_id) continue;
            if (limit) |lim| { if (count >= lim) break; }
            const body_owned = a.dupe(u8, e.body) catch return error.OutOfMemory;
            errdefer a.free(body_owned);
            out.append(a, .{
                .id = e.id,
                .task_id = e.task_id,
                .body = body_owned,
                .created_at = e.created_at,
            }) catch return error.OutOfMemory;
            count += 1;
        }
        return out.toOwnedSlice(a) catch return error.OutOfMemory;
    }

    fn latestFn(p: *anyopaque, a: std.mem.Allocator, task_id: d.ids.TaskId) d.ports.HandoffRepository.Error!?d.HandoffEntry {
        const self: *FakeHandoffRepo = @ptrCast(@alignCast(p));
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = self.entries.items[i];
            if (e.task_id == task_id) {
                const body_owned = a.dupe(u8, e.body) catch return error.OutOfMemory;
                return .{
                    .id = e.id,
                    .task_id = e.task_id,
                    .body = body_owned,
                    .created_at = e.created_at,
                };
            }
        }
        return null;
    }
};
