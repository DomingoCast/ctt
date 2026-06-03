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

pub const ColorScheme = struct {
    todo: ?[]const u8 = null,
    in_progress: ?[]const u8 = null,
    in_review: ?[]const u8 = null,
    done: ?[]const u8 = null,
    title: ?[]const u8 = null,
    metadata: ?[]const u8 = null,
    idle_pulse: ?[]const u8 = null,
};

pub const UiConfig = struct {
    spawn: ?[]const u8 = null,
    refresh_interval_ms: u32 = 2000,
    use_nerd_glyphs: bool = true,
    color_scheme: ColorScheme = .{},
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

fn isValidHex(s: []const u8) bool {
    if (s.len != 7 or s[0] != '#') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

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

    var parsed = std.json.parseFromSlice(Config, a, text, .{
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

    // Clamp refresh_interval_ms to [500, 60000] per spec §7
    const ui = &parsed.value.ui;
    if (ui.refresh_interval_ms < 500) ui.refresh_interval_ms = 500;
    if (ui.refresh_interval_ms > 60000) ui.refresh_interval_ms = 60000;

    // Validate color_scheme hex strings per spec §7
    const cs = &parsed.value.ui.color_scheme;
    inline for ([_]?[]const u8{ cs.todo, cs.in_progress, cs.in_review, cs.done, cs.title, cs.metadata, cs.idle_pulse }) |maybe| {
        if (maybe) |hex| {
            if (!isValidHex(hex)) {
                parsed.deinit();
                return error.BadFormat;
            }
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

test "load ui config with refresh interval and glyphs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/x","repos":[],"ui":{"refresh_interval_ms":1500,"use_nerd_glyphs":false}}
    );
    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);
    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1500), parsed.value.ui.refresh_interval_ms);
    try std.testing.expect(parsed.value.ui.use_nerd_glyphs == false);
}

test "load ui color_scheme partial override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeTmpFile(io, tmp.dir, "c.json",
        \\{"db_path":"/x","repos":[],"ui":{"color_scheme":{"todo":"#abcdef"}}}
    );
    const path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "c.json");
    defer std.testing.allocator.free(path);
    var parsed = try load(io, std.testing.allocator, path);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("#abcdef", parsed.value.ui.color_scheme.todo.?);
    try std.testing.expect(parsed.value.ui.color_scheme.in_progress == null);
}

test "load ui defaults when ui absent" {
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
    try std.testing.expectEqual(@as(u32, 2000), parsed.value.ui.refresh_interval_ms);
    try std.testing.expect(parsed.value.ui.use_nerd_glyphs == true);
}

test "load clamps refresh_interval_ms to [500, 60000]" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Too small → 500
    try writeTmpFile(io, tmp.dir, "low.json",
        \\{"db_path":"/x","repos":[],"ui":{"refresh_interval_ms":100}}
    );
    const low_path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "low.json");
    defer std.testing.allocator.free(low_path);
    var low = try load(io, std.testing.allocator, low_path);
    defer low.deinit();
    try std.testing.expectEqual(@as(u32, 500), low.value.ui.refresh_interval_ms);

    // Too large → 60000
    try writeTmpFile(io, tmp.dir, "high.json",
        \\{"db_path":"/x","repos":[],"ui":{"refresh_interval_ms":999999}}
    );
    const high_path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "high.json");
    defer std.testing.allocator.free(high_path);
    var high = try load(io, std.testing.allocator, high_path);
    defer high.deinit();
    try std.testing.expectEqual(@as(u32, 60000), high.value.ui.refresh_interval_ms);

    // In range passes through
    try writeTmpFile(io, tmp.dir, "ok.json",
        \\{"db_path":"/x","repos":[],"ui":{"refresh_interval_ms":3000}}
    );
    const ok_path = try tmpRealPath(io, std.testing.allocator, tmp.dir, "ok.json");
    defer std.testing.allocator.free(ok_path);
    var ok = try load(io, std.testing.allocator, ok_path);
    defer ok.deinit();
    try std.testing.expectEqual(@as(u32, 3000), ok.value.ui.refresh_interval_ms);
}

test "load rejects invalid color_scheme hex" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Bad format: missing #
    try writeTmpFile(io, tmp.dir, "bad1.json",
        \\{"db_path":"/x","repos":[],"ui":{"color_scheme":{"todo":"abcdef"}}}
    );
    const p1 = try tmpRealPath(io, std.testing.allocator, tmp.dir, "bad1.json");
    defer std.testing.allocator.free(p1);
    try std.testing.expectError(error.BadFormat, load(io, std.testing.allocator, p1));

    // Bad format: non-hex char
    try writeTmpFile(io, tmp.dir, "bad2.json",
        \\{"db_path":"/x","repos":[],"ui":{"color_scheme":{"in_progress":"#zzzzzz"}}}
    );
    const p2 = try tmpRealPath(io, std.testing.allocator, tmp.dir, "bad2.json");
    defer std.testing.allocator.free(p2);
    try std.testing.expectError(error.BadFormat, load(io, std.testing.allocator, p2));

    // Bad format: wrong length
    try writeTmpFile(io, tmp.dir, "bad3.json",
        \\{"db_path":"/x","repos":[],"ui":{"color_scheme":{"done":"#abc"}}}
    );
    const p3 = try tmpRealPath(io, std.testing.allocator, tmp.dir, "bad3.json");
    defer std.testing.allocator.free(p3);
    try std.testing.expectError(error.BadFormat, load(io, std.testing.allocator, p3));
}
