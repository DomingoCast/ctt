pub const GitWorktreeReader = @import("reader.zig").GitWorktreeReader;
pub const parsePorcelain = @import("reader.zig").parsePorcelain;

test {
    _ = @import("reader.zig");
}
