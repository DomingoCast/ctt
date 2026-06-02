const d = @import("domain");

pub const FakeClock = struct {
    value: d.Timestamp,

    pub fn init(value: d.Timestamp) FakeClock {
        return .{ .value = value };
    }
    pub fn interface(self: *FakeClock) d.ports.Clock {
        return .{ .ptr = self, .vtable = &vt };
    }
    const vt = d.ports.Clock.VTable{ .now = nowFn };

    fn nowFn(p: *anyopaque) d.Timestamp {
        const self: *FakeClock = @ptrCast(@alignCast(p));
        return self.value;
    }
};
