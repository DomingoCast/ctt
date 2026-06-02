pub const args = @import("args.zig");
pub const Command = args.Command;
pub const parse = args.parse;
pub const parseFromArgs = args.parseFromArgs;
pub const ParseError = args.ParseError;

test {
    _ = args;
}
