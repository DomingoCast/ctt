pub const app = @import("app.zig");
pub const view = @import("view.zig");
pub const state = @import("state.zig");
pub const modal = @import("modal.zig");
pub const terminal_launcher = @import("terminal_launcher.zig");
pub const project_candidates = @import("project_candidates.zig");
pub const fzf_picker = @import("fzf_picker.zig");
pub const UseCases = @import("use_cases.zig").UseCases;
pub const run = app.run;
pub const Selection = view.Selection;
pub const State = state.State;

test {
    _ = view;
    _ = state;
    _ = modal;
    _ = @import("use_cases.zig");
    _ = @import("theme.zig");
    _ = @import("glyphs.zig");
    _ = @import("card_layout.zig");
    _ = @import("tick.zig");
    // app.zig requires a real TTY, so don't include it in the test block
    _ = @import("repo_match.zig");
    _ = @import("terminal_launcher.zig");
    _ = @import("project_candidates.zig");
    _ = @import("fzf_picker.zig");
}
