pub const app = @import("app.zig");
pub const view = @import("view.zig");
pub const state = @import("state.zig");
pub const modal = @import("modal.zig");
pub const UseCases = @import("use_cases.zig").UseCases;
pub const run = app.run;
pub const Selection = view.Selection;
pub const State = state.State;

test {
    _ = view;
    _ = state;
    _ = modal;
    _ = @import("use_cases.zig");
    // app.zig requires a real TTY, so don't include it in the test block
}
