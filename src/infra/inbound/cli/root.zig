pub const args = @import("args.zig");
pub const Command = args.Command;
pub const parse = args.parse;
pub const parseFromArgs = args.parseFromArgs;
pub const ParseError = args.ParseError;

pub const UseCases = @import("use_cases.zig").UseCases;
pub const dispatch = @import("handlers.zig").dispatch;

test {
    _ = args;
    _ = @import("handlers.zig");
    _ = @import("use_cases.zig");
}
