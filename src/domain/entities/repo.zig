const ids = @import("../value_objects/ids.zig");

pub const Repo = struct {
    id: ids.RepoId,
    name: []const u8,
    root_path: []const u8,
    github: ?[]const u8,          // "owner/repo"
    default_branch: []const u8,
};

pub const RepoRef = struct {
    id: ids.RepoId,
    name: []const u8,
};
