const std = @import("std");

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 types
// ---------------------------------------------------------------------------

/// An inbound JSON-RPC request (or notification).
/// `id` is null for notifications (we ignore them).
/// `params` is the raw JSON value; individual method handlers parse it.
pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?std.json.Value = null,
    method: []const u8,
    params: ?std.json.Value = null,
};

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// Read the next newline-delimited JSON-RPC request from `reader`.
/// Returns null on EOF (clean end of stream).
/// The returned `Parsed` owns its memory; caller must call `.deinit()`.
pub fn readRequest(a: std.mem.Allocator, reader: *std.Io.Reader) !?std.json.Parsed(Request) {
    // Use takeDelimiter to read one line (excluding the '\n').
    // Returns null when there are no more bytes (EOF).
    const line = reader.takeDelimiter('\n') catch |err| switch (err) {
        error.ReadFailed => return null,
        error.StreamTooLong => return error.LineTooLong,
    };
    const slice = line orelse return null;
    if (slice.len == 0) return null;

    const parsed = try std.json.parseFromSlice(Request, a, slice, .{
        .ignore_unknown_fields = true,
    });
    return parsed;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// Write a successful JSON-RPC response.
/// `result_json` is a pre-serialised JSON string that becomes the "result" field.
pub fn writeResponse(writer: *std.Io.Writer, id: std.json.Value, result_json: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.writeAll(",\"result\":");
    try writer.writeAll(result_json);
    try writer.writeAll("}\n");
}

/// Write an error JSON-RPC response.
pub fn writeError(writer: *std.Io.Writer, id: std.json.Value, code: i32, message: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try writeJsonString(writer, message);
    try writer.writeAll("}}\n");
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

pub fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "readRequest parses a valid request" {
    const a = std.testing.allocator;
    const input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n";
    var r: std.Io.Reader = .fixed(input);
    const parsed = (try readRequest(a, &r)).?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("initialize", parsed.value.method);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.id.?.integer);
}

test "readRequest returns null on empty input" {
    const a = std.testing.allocator;
    var r: std.Io.Reader = .fixed("");
    const result = try readRequest(a, &r);
    try std.testing.expect(result == null);
}

test "readRequest returns null on blank line" {
    const a = std.testing.allocator;
    var r: std.Io.Reader = .fixed("\n");
    const result = try readRequest(a, &r);
    try std.testing.expect(result == null);
}

test "writeResponse produces valid JSON" {
    const a = std.testing.allocator;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();

    const id: std.json.Value = .{ .integer = 42 };
    try writeResponse(&w.writer, id, "{\"foo\":1}");

    const out = w.writer.buffered();
    // Must be valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trimEnd(u8, out, "\n"), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("id").?.integer);
}

test "writeError produces valid JSON with error object" {
    const a = std.testing.allocator;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();

    const id: std.json.Value = .null;
    try writeError(&w.writer, id, -32601, "method not found");

    const out = w.writer.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trimEnd(u8, out, "\n"), .{});
    defer parsed.deinit();
    const err_obj = parsed.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err_obj.get("code").?.integer);
    try std.testing.expectEqualStrings("method not found", err_obj.get("message").?.string);
}

test "writeJsonString escapes special characters" {
    const a = std.testing.allocator;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();

    try writeJsonString(&w.writer, "say \"hi\"\nC:\\path");
    try std.testing.expectEqualStrings("\"say \\\"hi\\\"\\nC:\\\\path\"", w.writer.buffered());
}

test "readRequest parses multiple requests from stream" {
    const a = std.testing.allocator;
    const input =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n";
    var r: std.Io.Reader = .fixed(input);

    const req1 = (try readRequest(a, &r)).?;
    defer req1.deinit();
    try std.testing.expectEqualStrings("initialize", req1.value.method);

    const req2 = (try readRequest(a, &r)).?;
    defer req2.deinit();
    try std.testing.expectEqualStrings("tools/list", req2.value.method);

    const eof = try readRequest(a, &r);
    try std.testing.expect(eof == null);
}
