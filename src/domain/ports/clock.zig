const Timestamp = @import("../value_objects/timestamp.zig").Timestamp;

pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now: *const fn (*anyopaque) Timestamp,
    };

    pub fn now(self: Clock) Timestamp { return self.vtable.now(self.ptr); }
};
