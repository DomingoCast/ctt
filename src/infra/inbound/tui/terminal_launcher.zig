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

pub const BuildArgvError = error{ NoTerminalDetected, OutOfMemory };

/// Builds the argv for `std.process.spawn` that opens a new terminal window
/// with cwd=`cwd` and running `/bin/sh -c "<cmd>"`.
///
/// The returned slice and each contained string are allocated with `a`;
/// caller must release via `freeArgv`.
pub fn buildArgv(
    a: std.mem.Allocator,
    launcher: Launcher,
    cwd: []const u8,
    cmd: []const u8,
) BuildArgvError![]const []const u8 {
    return switch (launcher.kind) {
        .wezterm => try dupeArgv(a, &[_][]const u8{
            "wezterm", "start", "--cwd", cwd, "--",
            "/bin/sh", "-c", cmd,
        }),
        .alacritty => try dupeArgv(a, &[_][]const u8{
            "alacritty", "--working-directory", cwd, "-e",
            "/bin/sh", "-c", cmd,
        }),
        .kitty => try dupeArgv(a, &[_][]const u8{
            "kitty", "--directory", cwd, "/bin/sh", "-c", cmd,
        }),
        .terminal_app => blk: {
            const cwd_quoted = try shSingleQuoteEscape(a, cwd);
            defer a.free(cwd_quoted);
            const script = try std.fmt.allocPrint(
                a,
                "tell application \"Terminal\" to do script \"cd '{s}' && {s}\"",
                .{ cwd_quoted, cmd },
            );
            defer a.free(script);
            break :blk try dupeArgv(a, &[_][]const u8{ "osascript", "-e", script });
        },
        .iterm2 => blk: {
            const cwd_quoted = try shSingleQuoteEscape(a, cwd);
            defer a.free(cwd_quoted);
            const script = try std.fmt.allocPrint(
                a,
                "tell application \"iTerm\"\n" ++
                    "  create window with default profile\n" ++
                    "  tell current session of current window to write text \"cd '{s}' && {s}\"\n" ++
                    "end tell",
                .{ cwd_quoted, cmd },
            );
            defer a.free(script);
            break :blk try dupeArgv(a, &[_][]const u8{ "osascript", "-e", script });
        },
        .none => return error.NoTerminalDetected,
    };
}

pub fn freeArgv(a: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |s| a.free(s);
    a.free(argv);
}

fn dupeArgv(a: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, src.len);
    errdefer a.free(out);
    var i: usize = 0;
    errdefer for (out[0..i]) |s| a.free(s);
    while (i < src.len) : (i += 1) {
        out[i] = try a.dupe(u8, src[i]);
    }
    return out;
}

/// Escapes a string for safe embedding inside single quotes in a POSIX shell.
/// `it's` → `it'\''s`. Caller owns the returned slice.
fn shSingleQuoteEscape(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(a, "'\\''");
        } else {
            try out.append(a, c);
        }
    }
    return out.toOwnedSlice(a);
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

fn argvEq(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (actual, expected) |a, e| try std.testing.expectEqualStrings(e, a);
}

test "buildArgv wezterm" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .wezterm }, "/home/me/proj", "claude --resume X");
    defer freeArgv(std.testing.allocator, argv);
    try argvEq(argv, &[_][]const u8{
        "wezterm", "start", "--cwd", "/home/me/proj", "--",
        "/bin/sh", "-c", "claude --resume X",
    });
}

test "buildArgv alacritty" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .alacritty }, "/home/me/proj", "claude");
    defer freeArgv(std.testing.allocator, argv);
    try argvEq(argv, &[_][]const u8{
        "alacritty", "--working-directory", "/home/me/proj", "-e",
        "/bin/sh", "-c", "claude",
    });
}

test "buildArgv kitty" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .kitty }, "/x", "ls");
    defer freeArgv(std.testing.allocator, argv);
    try argvEq(argv, &[_][]const u8{
        "kitty", "--directory", "/x", "/bin/sh", "-c", "ls",
    });
}

test "buildArgv .none returns NoTerminalDetected" {
    try std.testing.expectError(
        error.NoTerminalDetected,
        buildArgv(std.testing.allocator, .{ .kind = .none }, "/", "ls"),
    );
}

test "buildArgv terminal_app produces osascript do-script" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .terminal_app }, "/x", "claude");
    defer freeArgv(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("osascript", argv[0]);
    try std.testing.expectEqualStrings("-e", argv[1]);
    try std.testing.expectEqualStrings(
        "tell application \"Terminal\" to do script \"cd '/x' && claude\"",
        argv[2],
    );
}

test "buildArgv iterm2 produces osascript with create-window" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .iterm2 }, "/y", "ls");
    defer freeArgv(std.testing.allocator, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("osascript", argv[0]);
    try std.testing.expectEqualStrings("-e", argv[1]);
    const expected =
        "tell application \"iTerm\"\n" ++
        "  create window with default profile\n" ++
        "  tell current session of current window to write text \"cd '/y' && ls\"\n" ++
        "end tell";
    try std.testing.expectEqualStrings(expected, argv[2]);
}

test "buildArgv terminal_app escapes single quotes in cwd" {
    const argv = try buildArgv(std.testing.allocator, .{ .kind = .terminal_app }, "/it's/here", "ls");
    defer freeArgv(std.testing.allocator, argv);
    try std.testing.expectEqualStrings(
        "tell application \"Terminal\" to do script \"cd '/it'\\''s/here' && ls\"",
        argv[2],
    );
}
