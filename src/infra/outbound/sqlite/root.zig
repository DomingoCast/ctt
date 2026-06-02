pub const Db = @import("db.zig").Db;
pub const migrations = @import("migrations.zig");

test {
    _ = @import("db.zig");
}
