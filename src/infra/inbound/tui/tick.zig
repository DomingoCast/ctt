const std = @import("std");

/// Spawns a thread that posts a synthetic tick event into a vaxis Loop every
/// `interval_ms`. The thread reads `stop.*` and exits when true.
pub fn TickThread(comptime Loop: type, comptime Event: type) type {
    return struct {
        thread: std.Thread,
        stop: *std.atomic.Value(bool),

        const Self = @This();

        pub fn start(loop: *Loop, stop: *std.atomic.Value(bool), interval_ms: u32) !Self {
            const thread = try std.Thread.spawn(.{}, threadFn, .{ loop, stop, interval_ms });
            return .{
                .thread = thread,
                .stop = stop,
            };
        }

        pub fn join(self: *Self) void {
            self.stop.store(true, .release);
            self.thread.join();
        }

        fn threadFn(loop: *Loop, stop: *std.atomic.Value(bool), interval_ms: u32) void {
            const ns_per_ms: u64 = std.time.ns_per_ms;
            const sleep_ns: u64 = @as(u64, interval_ms) * ns_per_ms;
            const req = std.c.timespec{
                .sec = @intCast(sleep_ns / std.time.ns_per_s),
                .nsec = @intCast(sleep_ns % std.time.ns_per_s),
            };
            while (!stop.load(.acquire)) {
                _ = std.c.nanosleep(&req, null);
                if (stop.load(.acquire)) break;
                loop.postEvent(Event{ .tick = {} }) catch break;
            }
        }
    };
}
