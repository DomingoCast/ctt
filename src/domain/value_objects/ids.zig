const std = @import("std");

pub const TaskId      = enum(i64) { _, pub fn raw(self: TaskId) i64 { return @intFromEnum(self); } };
pub const WorktreeId  = enum(i64) { _, pub fn raw(self: WorktreeId) i64 { return @intFromEnum(self); } };
pub const PrId        = enum(i64) { _, pub fn raw(self: PrId) i64 { return @intFromEnum(self); } };
pub const IssueId     = enum(i64) { _, pub fn raw(self: IssueId) i64 { return @intFromEnum(self); } };
pub const RepoId      = enum(i64) { _, pub fn raw(self: RepoId) i64 { return @intFromEnum(self); } };
pub const ProviderId  = []const u8; // e.g. "linear", "jira"
