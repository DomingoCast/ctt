const ids = @import("../value_objects/ids.zig");
const BranchName = @import("../value_objects/branch_name.zig").BranchName;
const Timestamp = @import("../value_objects/timestamp.zig").Timestamp;
const Url = @import("../value_objects/url.zig").Url;
const RepoRef = @import("repo.zig").RepoRef;
const PrState = @import("status.zig").PrState;

pub const Pr = struct {
    id: ids.PrId,
    repo: RepoRef,
    number: u32,
    url: Url,
    title: []const u8,
    head_branch: BranchName,
    state: PrState,
    updated_at: Timestamp,
    fetched_at: Timestamp,
};

pub const PrSnapshot = struct {
    number: u32,
    url: Url,
    title: []const u8,
    head_branch: BranchName,
    state: PrState,
    updated_at: Timestamp,
};
