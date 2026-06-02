pub const app = @import("app.zig");
pub const view = @import("view.zig");
pub const run = app.run;
pub const Selection = view.Selection;

test {
    _ = @import("app.zig");
    _ = @import("view.zig");
}
