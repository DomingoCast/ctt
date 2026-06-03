const std = @import("std");

pub const SessionHandle = struct {
    provider: []const u8,    // e.g. "claude", "codex" — opaque to ctt
    session_id: []const u8,  // opaque to ctt

    pub fn eql(a: SessionHandle, b: SessionHandle) bool {
        return std.mem.eql(u8, a.provider, b.provider)
            and std.mem.eql(u8, a.session_id, b.session_id);
    }
};

test "eql is true for identical handles" {
    const h1 = SessionHandle{ .provider = "claude", .session_id = "abc" };
    const h2 = SessionHandle{ .provider = "claude", .session_id = "abc" };
    try std.testing.expect(h1.eql(h2));
}

test "eql is false when provider differs" {
    const h1 = SessionHandle{ .provider = "claude", .session_id = "abc" };
    const h2 = SessionHandle{ .provider = "codex", .session_id = "abc" };
    try std.testing.expect(!h1.eql(h2));
}

test "eql is false when session_id differs" {
    const h1 = SessionHandle{ .provider = "claude", .session_id = "abc" };
    const h2 = SessionHandle{ .provider = "claude", .session_id = "xyz" };
    try std.testing.expect(!h1.eql(h2));
}
