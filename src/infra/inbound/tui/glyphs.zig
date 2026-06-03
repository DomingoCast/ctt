const std = @import("std");

pub const GlyphSet = struct {
    branch:    []const u8,
    repo:      []const u8,
    pr:        []const u8,
    issue:     []const u8,
    folder:    []const u8,
    ai:        []const u8,
    edit:      []const u8,
    save:      []const u8,

    pub const nerd = GlyphSet{
        .branch = "\u{ea68}",  // nf-cod-source_control
        .repo   = "\u{ea83}",  // nf-cod-repo
        .pr     = "\u{eaa3}",  // nf-cod-git_pull_request
        .issue  = "\u{eab2}",  // nf-cod-issues
        .folder = "\u{ea83}",
        .ai     = "\u{ec1d}",  // nf-cod-robot
        .edit   = "\u{ea73}",  // nf-cod-edit
        .save   = "\u{eb4b}",  // nf-cod-save
    };

    pub const ascii = GlyphSet{
        .branch = "b:",
        .repo   = "r:",
        .pr     = "pr:",
        .issue  = "i:",
        .folder = "d:",
        .ai     = "[AI]",
        .edit   = "[edit]",
        .save   = "[save]",
    };

    pub fn select(use_nerd: bool) GlyphSet {
        return if (use_nerd) nerd else ascii;
    }
};

test "select returns nerd or ascii" {
    const n = GlyphSet.select(true);
    const a = GlyphSet.select(false);
    try std.testing.expectEqualStrings("[AI]", a.ai);
    try std.testing.expect(!std.mem.eql(u8, n.ai, a.ai));
}

test "nerd glyphs are non-empty unicode" {
    const n = GlyphSet.nerd;
    try std.testing.expect(n.branch.len > 0);
    try std.testing.expect(n.pr.len > 0);
}
