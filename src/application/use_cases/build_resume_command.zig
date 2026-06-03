const std = @import("std");
const d = @import("domain");

/// A rendered, ready-to-spawn command.
pub const ResumeCommand = struct {
    command: []const u8, // caller-owned; free with the allocator passed to build()
    mode: enum { resume_session, fresh_with_context },
};

pub const BuildError = error{
    NoTemplateForProvider,
    NoDefaultProvider,
    OutOfMemory,
};

/// Mirrors the in-config `ProviderTemplates` but lives in the application layer so
/// the layer doesn't import infra. The composition root (main.zig) bridges between
/// the two shapes.
pub const ProviderTemplate = struct {
    @"resume": ?[]const u8 = null,
    fresh: ?[]const u8 = null,
    icon: ?[]const u8 = null,
};

pub const Inputs = struct {
    /// Lookup function: caller knows where the templates map lives.
    templates: *const fn (provider: []const u8) ?ProviderTemplate,
    default_provider: ?[]const u8,
    session: ?d.SessionHandle,
    /// Path to a temp file containing the latest handoff body (or an empty file).
    /// Required only when the fresh template uses `{{context_file}}`.
    context_file: ?[]const u8,
    /// If non-null, wrap the rendered inner command with this template via `{{cmd}}`.
    spawn_wrapper: ?[]const u8,
    /// Force fresh mode even when a session handle is present.
    force_fresh: bool,
};

pub fn build(a: std.mem.Allocator, inp: Inputs) BuildError!ResumeCommand {
    // 1. Pick provider name.
    //    Always prefer a session's provider (for template lookup), unless there's
    //    no session at all — in that case fall back to the default_provider.
    const provider: []const u8 = blk: {
        if (inp.session) |s| {
            break :blk s.provider;
        }
        if (inp.default_provider) |dp| {
            break :blk dp;
        }
        return error.NoDefaultProvider;
    };

    // 2. Look up the template entry.
    const tmpl = inp.templates(provider) orelse return error.NoTemplateForProvider;

    // 3. Decide mode and render inner template.
    const use_resume = !inp.force_fresh and inp.session != null and tmpl.@"resume" != null;

    var inner: []u8 = undefined;
    const mode: @TypeOf((ResumeCommand{ .command = "", .mode = .resume_session }).mode) = if (use_resume) blk: {
        const session_id = inp.session.?.session_id;
        inner = try std.mem.replaceOwned(u8, a, tmpl.@"resume".?, "{{session_id}}", session_id);
        break :blk .resume_session;
    } else blk: {
        const fresh_tmpl = tmpl.fresh orelse return error.NoTemplateForProvider;
        const context = inp.context_file orelse "";
        inner = try std.mem.replaceOwned(u8, a, fresh_tmpl, "{{context_file}}", context);
        break :blk .fresh_with_context;
    };

    // 5. Wrap with spawn template if present.
    const command: []u8 = if (inp.spawn_wrapper) |wrapper| blk: {
        const wrapped = try std.mem.replaceOwned(u8, a, wrapper, "{{cmd}}", inner);
        a.free(inner);
        break :blk wrapped;
    } else inner;

    return ResumeCommand{ .command = command, .mode = mode };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn fixedTemplates(comptime entry: ProviderTemplate) fn ([]const u8) ?ProviderTemplate {
    return struct {
        fn lookup(_: []const u8) ?ProviderTemplate {
            return entry;
        }
    }.lookup;
}

test "resume mode substitutes session_id" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .@"resume" = "claude --resume {{session_id}}" }),
        .default_provider = null,
        .session = .{ .provider = "claude", .session_id = "abc-123" },
        .context_file = null,
        .spawn_wrapper = null,
        .force_fresh = false,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("claude --resume abc-123", result.command);
    try std.testing.expectEqual(@as(@TypeOf(result.mode), .resume_session), result.mode);
}

test "fresh mode substitutes context_file" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .fresh = "claude --append-system-prompt \"$(cat {{context_file}})\"" }),
        .default_provider = "claude",
        .session = null,
        .context_file = "/tmp/x.md",
        .spawn_wrapper = null,
        .force_fresh = false,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("claude --append-system-prompt \"$(cat /tmp/x.md)\"", result.command);
    try std.testing.expectEqual(@as(@TypeOf(result.mode), .fresh_with_context), result.mode);
}

test "force_fresh ignores session handle" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .@"resume" = "R{{session_id}}", .fresh = "F{{context_file}}" }),
        .default_provider = null,
        .session = .{ .provider = "claude", .session_id = "abc" },
        .context_file = "/tmp/y.md",
        .spawn_wrapper = null,
        .force_fresh = true,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("F/tmp/y.md", result.command);
}

test "spawn wrapper wraps the inner command" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .@"resume" = "claude --resume {{session_id}}" }),
        .default_provider = null,
        .session = .{ .provider = "claude", .session_id = "abc" },
        .context_file = null,
        .spawn_wrapper = "tmux new-window -- {{cmd}}",
        .force_fresh = false,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("tmux new-window -- claude --resume abc", result.command);
}

test "missing template returns error" {
    const a = std.testing.allocator;
    const lookup = struct {
        fn f(_: []const u8) ?ProviderTemplate {
            return null;
        }
    }.f;
    try std.testing.expectError(error.NoTemplateForProvider, build(a, .{
        .templates = lookup,
        .default_provider = "claude",
        .session = null,
        .context_file = "/tmp/x",
        .spawn_wrapper = null,
        .force_fresh = false,
    }));
}

test "no session and no default returns error" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NoDefaultProvider, build(a, .{
        .templates = fixedTemplates(.{ .fresh = "F{{context_file}}" }),
        .default_provider = null,
        .session = null,
        .context_file = null,
        .spawn_wrapper = null,
        .force_fresh = false,
    }));
}

test "missing context_file substitutes empty string" {
    const a = std.testing.allocator;
    const result = try build(a, .{
        .templates = fixedTemplates(.{ .fresh = "claude < {{context_file}}" }),
        .default_provider = "claude",
        .session = null,
        .context_file = null,
        .spawn_wrapper = null,
        .force_fresh = false,
    });
    defer a.free(result.command);
    try std.testing.expectEqualStrings("claude < ", result.command);
}
