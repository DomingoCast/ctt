pub const GhPrGateway = @import("gateway.zig").GhPrGateway;
pub const parseGhJson = @import("gateway.zig").parseGhJson;

test {
    _ = @import("gateway.zig");
}
