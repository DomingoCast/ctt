const std = @import("std");

pub const Kind = enum { wezterm, kitty, alacritty, iterm2, terminal_app, none };

pub const Launcher = struct {
    kind: Kind,
};

/// Inspect env vars and return the first matching terminal kind.
/// Priority: wezterm > kitty > alacritty > iterm2 > terminal_app.
pub fn detect(env: *const std.process.Environ.Map) Launcher {
    if (env.get("WEZTERM_EXECUTABLE") != null or env.get("WEZTERM_PANE") != null) {
        return .{ .kind = .wezterm };
    }
    if (env.get("KITTY_WINDOW_ID") != null) {
        return .{ .kind = .kitty };
    }
    if (env.get("ALACRITTY_LOG") != null or env.get("ALACRITTY_SOCKET") != null) {
        return .{ .kind = .alacritty };
    }
    if (env.get("TERM_PROGRAM")) |tp| {
        if (std.mem.eql(u8, tp, "iTerm.app")) return .{ .kind = .iterm2 };
        if (std.mem.eql(u8, tp, "Apple_Terminal")) return .{ .kind = .terminal_app };
    }
    return .{ .kind = .none };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "detect returns .none for empty env" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(Kind.none, detect(&env).kind);
}

test "detect wezterm via WEZTERM_PANE" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEZTERM_PANE", "0");
    try std.testing.expectEqual(Kind.wezterm, detect(&env).kind);
}

test "detect wezterm via WEZTERM_EXECUTABLE" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEZTERM_EXECUTABLE", "/usr/bin/wezterm");
    try std.testing.expectEqual(Kind.wezterm, detect(&env).kind);
}

test "detect kitty via KITTY_WINDOW_ID" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("KITTY_WINDOW_ID", "1");
    try std.testing.expectEqual(Kind.kitty, detect(&env).kind);
}

test "detect alacritty via ALACRITTY_LOG" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ALACRITTY_LOG", "/tmp/alacritty.log");
    try std.testing.expectEqual(Kind.alacritty, detect(&env).kind);
}

test "detect alacritty via ALACRITTY_SOCKET" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ALACRITTY_SOCKET", "/tmp/alacritty.sock");
    try std.testing.expectEqual(Kind.alacritty, detect(&env).kind);
}

test "detect iterm2 via TERM_PROGRAM" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM_PROGRAM", "iTerm.app");
    try std.testing.expectEqual(Kind.iterm2, detect(&env).kind);
}

test "detect terminal_app via TERM_PROGRAM" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM_PROGRAM", "Apple_Terminal");
    try std.testing.expectEqual(Kind.terminal_app, detect(&env).kind);
}

test "detect priority: wezterm beats alacritty when both set" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("WEZTERM_PANE", "0");
    try env.put("ALACRITTY_LOG", "/tmp/a.log");
    try std.testing.expectEqual(Kind.wezterm, detect(&env).kind);
}

test "detect TERM_PROGRAM unknown value returns .none" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM_PROGRAM", "weird-terminal");
    try std.testing.expectEqual(Kind.none, detect(&env).kind);
}
