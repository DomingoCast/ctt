const std = @import("std");

pub const BranchName = struct {
    value: []const u8,

    pub fn init(s: []const u8) BranchName {
        return .{ .value = s };
    }
    pub fn eql(a: BranchName, b: BranchName) bool {
        return std.mem.eql(u8, a.value, b.value);
    }
};
