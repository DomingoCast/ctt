pub const LinearIssueGateway = @import("gateway.zig").LinearIssueGateway;
pub const buildQuery = @import("gateway.zig").buildQuery;
pub const parseResponse = @import("gateway.zig").parseResponse;

test {
    _ = @import("gateway.zig");
}
