const std = @import("std");
const d = @import("domain");

// ─── GraphQL helpers ──────────────────────────────────────────────────────────

pub fn buildQuery(a: std.mem.Allocator, external_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        "{{\"query\":\"query($id:String!){{issue(id:$id){{identifier url title state{{name}}}}}}\",\"variables\":{{\"id\":\"{s}\"}}}}",
        .{external_id},
    );
}

pub fn parseResponse(a: std.mem.Allocator, body: []const u8) !?d.IssueSnapshot {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return null;
    if (data != .object) return null;
    const issue = data.object.get("issue") orelse return null;
    if (issue == .null) return null;
    if (issue != .object) return null;
    const obj = issue.object;

    const external_id_dup = try a.dupe(u8, obj.get("identifier").?.string);
    errdefer a.free(external_id_dup);

    const url_dup = if (obj.get("url")) |v| (if (v == .string) try a.dupe(u8, v.string) else null) else null;
    errdefer if (url_dup) |u| a.free(u);

    const title_dup = if (obj.get("title")) |v| (if (v == .string) try a.dupe(u8, v.string) else null) else null;
    errdefer if (title_dup) |t| a.free(t);

    const state_obj = obj.get("state");
    const state_name = if (state_obj) |s| (if (s == .object) s.object.get("name") else null) else null;
    const state_dup = if (state_name) |v| (if (v == .string) try a.dupe(u8, v.string) else null) else null;
    errdefer if (state_dup) |s| a.free(s);

    return d.IssueSnapshot{
        .external_id = external_id_dup,
        .url = url_dup,
        .title = title_dup,
        .state = state_dup,
    };
}

// ─── LinearIssueGateway ───────────────────────────────────────────────────────
//
// HTTP transport: native std.http.Client (Zig 0.16).
//   - Client requires both `allocator` and `io: std.Io`.
//   - Response is captured via `std.Io.Writer.Allocating` (growing heap buffer),
//     passed as `response_writer: &resp_writer.writer` in FetchOptions.
//   - Body slice is `resp_writer.writer.buffer[0..resp_writer.writer.end]`.

pub const LinearIssueGateway = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    token: []const u8,

    pub fn init(a: std.mem.Allocator, io: std.Io, token: []const u8) LinearIssueGateway {
        return .{ .allocator = a, .io = io, .token = token };
    }

    pub fn interface(self: *LinearIssueGateway) d.ports.IssueGateway {
        return .{ .ptr = self, .vtable = &vt };
    }

    const vt = d.ports.IssueGateway.VTable{ .provider_id = providerIdFn, .fetch = fetchFn };

    fn providerIdFn(_: *anyopaque) d.ids.ProviderId {
        return "linear";
    }

    fn fetchFn(p: *anyopaque, a: std.mem.Allocator, external_id: []const u8) d.ports.IssueGateway.Error!?d.IssueSnapshot {
        const self: *LinearIssueGateway = @ptrCast(@alignCast(p));
        if (self.token.len == 0) return error.NotConfigured;

        const body = buildQuery(a, external_id) catch return error.OutOfMemory;
        defer a.free(body);

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var resp_writer: std.Io.Writer.Allocating = .init(a);
        defer resp_writer.deinit();

        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = self.token },
            .{ .name = "Content-Type", .value = "application/json" },
        };

        const result = client.fetch(.{
            .location = .{ .url = "https://api.linear.app/graphql" },
            .method = .POST,
            .payload = body,
            .extra_headers = &headers,
            .response_writer = &resp_writer.writer,
        }) catch return error.Io;

        if (result.status != .ok) return error.AuthFailed;

        const resp_body = resp_writer.writer.buffer[0..resp_writer.writer.end];
        return parseResponse(a, resp_body) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadFormat,
        };
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "parses issue response" {
    const body = "{\"data\":{\"issue\":{\"identifier\":\"MOE-272\",\"url\":\"https://x\",\"title\":\"t\",\"state\":{\"name\":\"In Progress\"}}}}";
    const got = (try parseResponse(std.testing.allocator, body)).?;
    defer {
        std.testing.allocator.free(got.external_id);
        if (got.url) |u| std.testing.allocator.free(u);
        if (got.title) |t| std.testing.allocator.free(t);
        if (got.state) |s| std.testing.allocator.free(s);
    }
    try std.testing.expectEqualStrings("MOE-272", got.external_id);
    try std.testing.expectEqualStrings("In Progress", got.state.?);
}

test "null issue returns null" {
    const body = "{\"data\":{\"issue\":null}}";
    const got = try parseResponse(std.testing.allocator, body);
    try std.testing.expectEqual(@as(?d.IssueSnapshot, null), got);
}

test "missing data field returns null" {
    const body = "{}";
    const got = try parseResponse(std.testing.allocator, body);
    try std.testing.expectEqual(@as(?d.IssueSnapshot, null), got);
}

test "builds query with given id" {
    const q = try buildQuery(std.testing.allocator, "MOE-272");
    defer std.testing.allocator.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "MOE-272") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "query($id:String!)") != null);
}
