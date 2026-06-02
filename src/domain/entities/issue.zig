const ids = @import("../value_objects/ids.zig");
const Timestamp = @import("../value_objects/timestamp.zig").Timestamp;

pub const Issue = struct {
    id: ids.IssueId,
    provider: ids.ProviderId,
    external_id: []const u8,
    url: ?[]const u8,
    title: ?[]const u8,
    state: ?[]const u8,
    fetched_at: Timestamp,
};

pub const IssueSnapshot = struct {
    external_id: []const u8,
    url: ?[]const u8,
    title: ?[]const u8,
    state: ?[]const u8,
};
