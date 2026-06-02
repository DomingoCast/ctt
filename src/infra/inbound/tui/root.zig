pub const app = @import("app.zig");
pub const run = app.run;

test {
    // The test below would require a real TTY, so just verify the file compiles.
    _ = @import("app.zig");
}
