const std = @import("std");
const vaxis = @import("vaxis");
const view = @import("view.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

/// Run the TUI event loop.
///
/// Callers must supply `io` (a `std.Io` backend) and `env_map` (the process
/// environment map) because libvaxis 0.6 requires both at construction time.
/// A typical `main` obtains these from `std.Io.Threaded` and
/// `std.process.Environ.createMap`.
pub fn run(
    io: std.Io,
    alloc: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
) !void {
    // Provide a stack buffer for the TTY writer.
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(io, alloc, env_map, .{});
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    if (!vx.state.in_band_resize) try loop.installResizeHandler();

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |k| if (k.matches('q', .{})) break,
            .winsize => |ws| try vx.resize(alloc, tty.writer(), ws),
        }
        const win = vx.window();
        view.render(win, &.{}, .{}); // empty views; will get populated in Task 8.3
        try vx.render(tty.writer());
    }
}
