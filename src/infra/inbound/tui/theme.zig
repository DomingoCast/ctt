const std = @import("std");
const vaxis = @import("vaxis");
const d = @import("domain");
const cfg = @import("infra_config");

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn dim(self: RGB) RGB {
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) * 0.6),
            .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) * 0.6),
            .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) * 0.6),
        };
    }

    pub fn toVaxis(self: RGB) vaxis.Color {
        return .{ .rgb = [3]u8{ self.r, self.g, self.b } };
    }
};

pub const ColorScheme = struct {
    todo: RGB,
    in_progress: RGB,
    in_review: RGB,
    done: RGB,
    title: RGB,
    metadata: RGB,
    idle_pulse: RGB,

    pub const default = ColorScheme{
        .todo        = .{ .r = 0x7a, .g = 0xa2, .b = 0xf7 },
        .in_progress = .{ .r = 0xe0, .g = 0xaf, .b = 0x68 },
        .in_review   = .{ .r = 0xbb, .g = 0x9a, .b = 0xf7 },
        .done        = .{ .r = 0x9e, .g = 0xce, .b = 0x6a },
        .title       = .{ .r = 0xc0, .g = 0xca, .b = 0xf5 },
        .metadata    = .{ .r = 0x56, .g = 0x5f, .b = 0x89 },
        .idle_pulse  = .{ .r = 0x41, .g = 0x48, .b = 0x68 },
    };

    pub fn fromConfig(c: cfg.ColorScheme) ColorScheme {
        return .{
            .todo        = parseHex(c.todo)        orelse default.todo,
            .in_progress = parseHex(c.in_progress) orelse default.in_progress,
            .in_review   = parseHex(c.in_review)   orelse default.in_review,
            .done        = parseHex(c.done)        orelse default.done,
            .title       = parseHex(c.title)       orelse default.title,
            .metadata    = parseHex(c.metadata)    orelse default.metadata,
            .idle_pulse  = parseHex(c.idle_pulse)  orelse default.idle_pulse,
        };
    }

    pub fn forColumn(self: ColorScheme, status: d.Status) RGB {
        return switch (status) {
            .todo => self.todo,
            .in_progress => self.in_progress,
            .in_review => self.in_review,
            .done => self.done,
            .archived => self.metadata,
        };
    }
};

fn parseHex(maybe_hex: ?[]const u8) ?RGB {
    const hex = maybe_hex orelse return null;
    if (hex.len != 7 or hex[0] != '#') return null;
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

test "dim scales channels to 60%" {
    const rgb = RGB{ .r = 100, .g = 200, .b = 250 };
    const d_rgb = rgb.dim();
    try std.testing.expectEqual(@as(u8, 60), d_rgb.r);
    try std.testing.expectEqual(@as(u8, 120), d_rgb.g);
    try std.testing.expectEqual(@as(u8, 150), d_rgb.b);
}

test "parseHex valid" {
    const rgb = parseHex("#7aa2f7").?;
    try std.testing.expectEqual(@as(u8, 0x7a), rgb.r);
    try std.testing.expectEqual(@as(u8, 0xa2), rgb.g);
    try std.testing.expectEqual(@as(u8, 0xf7), rgb.b);
}

test "parseHex invalid returns null" {
    try std.testing.expect(parseHex("not-hex") == null);
    try std.testing.expect(parseHex("#abc") == null);
    try std.testing.expect(parseHex(null) == null);
    try std.testing.expect(parseHex("#zzzzzz") == null);
}

test "fromConfig partial override" {
    var c = cfg.ColorScheme{};
    c.todo = "#000000";
    const scheme = ColorScheme.fromConfig(c);
    try std.testing.expectEqual(@as(u8, 0), scheme.todo.r);
    try std.testing.expectEqual(@as(u8, 0xe0), scheme.in_progress.r);
}

test "forColumn maps status to color" {
    const scheme = ColorScheme.default;
    try std.testing.expectEqual(scheme.todo, scheme.forColumn(.todo));
    try std.testing.expectEqual(scheme.done, scheme.forColumn(.done));
}
