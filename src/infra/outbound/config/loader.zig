const std = @import("std");

pub const RepoConfig = struct {
    name: []const u8,
    path: []const u8,
    github: ?[]const u8 = null,
    default_branch: []const u8 = "main",
};

pub const PatternConfig = struct {
    provider: []const u8,
    prefix_min: u8 = 2,
    prefix_max: u8 = 6,
};

pub const RefreshConfig = struct {
    issue_cache_ttl_secs: u32 = 300,
};

pub const ProviderTemplates = struct {
    @"resume": ?[]const u8 = null,
    fresh: ?[]const u8 = null,
    /// Short string (emoji or 1-3 chars) shown on the TUI card.
    icon: ?[]const u8 = null,
};

pub const UiConfig = struct {
    spawn: ?[]const u8 = null,
};

pub const ProvidersConfig = struct {
    linear: LinearConfig = .{},
    patterns: []PatternConfig = &[_]PatternConfig{},
    default: ?[]const u8 = null,
    templates: std.json.ArrayHashMap(ProviderTemplates) = .{},
};

pub const LinearConfig = struct {
    enabled: bool = true,
};

pub const Config = struct {
    db_path: []const u8,
    default_browser: ?[]const u8 = null,
    repos: []RepoConfig,
    providers: ProvidersConfig = .{},
    refresh: RefreshConfig = .{},
    ui: UiConfig = .{},
};

pub const LoadError = error{
    InsecureSecretsFile,
    OutOfMemory,
    Io,
    BadFormat,
};

/// Loads config.json from the given absolute path.
/// The returned `Parsed(Config)` must be `.deinit()`-ed by the caller.
/// All `[]const u8` values inside the returned `Config` (including provider
/// template strings, repo paths, etc.) are arena-owned by the `Parsed`;
/// callers must not store slices past `parsed.deinit()`.
pub fn load(io: std.Io, a: std.mem.Allocator, path: []const u8) LoadError!std.json.Parsed(Config) {
    const text = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        path,
        a,
        .limited(1 * 1024 * 1024),
    ) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
    defer a.free(text);

    const parsed = std.json.parseFromSlice(Config, a, text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.BadFormat,
    };

    if (parsed.value.providers.default) |name| {
        if (parsed.value.providers.templates.map.get(name) == null) {
            parsed.deinit();
            return error.BadFormat;
        }
    }

    return parsed;
}

/// Loads the Linear API token.
/// Order of precedence:
///   1. CTT_LINEAR_TOKEN environment variable (takes precedence, always checked first)
///   2. secrets.json file at `path` — **must** be mode 0600 or stricter.
///
/// Returns `null` when the secrets file is missing and the env var is unset.
/// Caller owns the returned string.
pub fn loadSecretsToken(io: std.Io, a: std.mem.Allocator, path: []const u8) LoadError!?[]const u8 {
    // 1. env var wins
    if (std.c.getenv("CTT_LINEAR_TOKEN")) |ptr| {
        const s = std.mem.span(ptr);
        if (s.len > 0) return a.dupe(u8, s) catch return error.OutOfMemory;
    }

    // 2. secrets.json — file missing is not an error, just no token
    const stat = std.Io.Dir.statFile(
        std.Io.Dir.cwd(),
        io,
        path,
        .{},
    ) catch return null;

    // Enforce 0600: world bits and group bits must both be zero
    const mode = stat.permissions.toMode();
    if ((mode & 0o077) != 0) return error.InsecureSecretsFile;

    const text = std.Io.Dir.readFileAlloc(
        std.Io.Dir.cwd(),
        io,
        path,
        a,
        .limited(4096),
    ) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Io,
    };
    defer a.free(text);

    const Secrets = struct { linear_token: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Secrets, a, text, .{ .ignore_unknown_fields = true }) catch return error.BadFormat;
    defer parsed.deinit();

    return if (parsed.value.linear_token) |t| a.dupe(u8, t) catch error.OutOfMemory else null;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

fn writeTmpFile(io: std.Io, dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

fn tmpRealPath(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &buf);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ buf[0..n], name });
}

test "load minimal config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/tmp/a","repos":[]}
    );

    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);

    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("/tmp/a", parsed.value.db_path);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.repos.len);
    try std.testing.expectEqual(@as(u32, 300), parsed.value.refresh.issue_cache_ttl_secs);
}

test "load config with repos" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/x","repos":[{"name":"r1","path":"/r1","github":"o/r1"}]}
    );

    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);

    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.repos.len);
    try std.testing.expectEqualStrings("r1", parsed.value.repos[0].name);
    try std.testing.expectEqualStrings("o/r1", parsed.value.repos[0].github.?);
    try std.testing.expectEqualStrings("main", parsed.value.repos[0].default_branch);
}

test "load returns BadFormat on invalid json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json", "not json");

    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.BadFormat, load(io, std.testing.allocator, path));
}

test "load returns Io on missing file" {
    const io = std.testing.io;
    try std.testing.expectError(error.Io, load(io, std.testing.allocator, "/nonexistent/config.json"));
}

test "loadSecretsToken returns null when missing" {
    const io = std.testing.io;
    const got = try loadSecretsToken(io, std.testing.allocator, "/nonexistent/secrets.json");
    try std.testing.expectEqual(@as(?[]const u8, null), got);
}

test "loadSecretsToken rejects world-readable file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "secrets.json",
        \\{"linear_token":"x"}
    );

    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "secrets.json");
    defer std.testing.allocator.free(path);

    // chmod to 0644 — world-readable — must fail
    try tmp.dir.setFilePermissions(io, "secrets.json", .fromMode(0o644), .{});
    try std.testing.expectError(error.InsecureSecretsFile, loadSecretsToken(io, std.testing.allocator, path));
}

test "loadSecretsToken reads token from 0600 file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "secrets.json",
        \\{"linear_token":"abc123"}
    );

    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "secrets.json");
    defer std.testing.allocator.free(path);

    try tmp.dir.setFilePermissions(io, "secrets.json", .fromMode(0o600), .{});
    const got = (try loadSecretsToken(io, std.testing.allocator, path)).?;
    defer std.testing.allocator.free(got);

    try std.testing.expectEqualStrings("abc123", got);
}

test "load config with provider templates and ui" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{
        \\  "db_path":"/x","repos":[],
        \\  "providers":{
        \\    "patterns":[],
        \\    "default":"claude",
        \\    "templates":{
        \\      "claude":{"resume":"claude --resume {{session_id}}","fresh":"claude","icon":"C"}
        \\    }
        \\  },
        \\  "ui":{"spawn":"tmux new-window -- {{cmd}}"}
        \\}
    );
    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);

    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("claude", parsed.value.providers.default.?);

    const tmpl_opt = parsed.value.providers.templates.map.get("claude");
    const tmpl = tmpl_opt.?;
    try std.testing.expectEqualStrings("claude --resume {{session_id}}", tmpl.@"resume".?);
    try std.testing.expectEqualStrings("claude", tmpl.fresh.?);
    try std.testing.expectEqualStrings("C", tmpl.icon.?);
    try std.testing.expectEqualStrings("tmux new-window -- {{cmd}}", parsed.value.ui.spawn.?);
}

test "minimal config has empty templates and null defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/x","repos":[]}
    );
    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);

    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.providers.default == null);
    try std.testing.expect(parsed.value.ui.spawn == null);
    const tmpl_size: usize = parsed.value.providers.templates.map.count();
    try std.testing.expectEqual(@as(usize, 0), tmpl_size);
}

test "load rejects providers.default that is not in providers.templates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/x","repos":[],"providers":{"default":"missing"}}
    );
    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.BadFormat, load(io, std.testing.allocator, path));
}
