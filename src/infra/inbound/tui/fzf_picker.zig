const std = @import("std");
const project_candidates = @import("project_candidates.zig");

pub const Selection = struct {
    name: []const u8,
    path: []const u8,
};

pub fn freeSelection(a: std.mem.Allocator, sel: Selection) void {
    a.free(sel.name);
    a.free(sel.path);
}

/// Spawn `fzf`, write `name\tpath\n` for each candidate to its stdin, then
/// read the selected line from stdout. Returns null if the user pressed Esc,
/// fzf exited non-zero, or no selection was made.
///
/// IMPORTANT: this function blocks while fzf is running. It assumes the
/// caller has already suspended the TUI (left the alternate screen, restored
/// canonical line mode). It does NOT suspend/resume itself — that's the
/// caller's responsibility (handled in Task 13).
///
/// The returned `Selection`'s `name` and `path` are owned by `a`; free via
/// `freeSelection`.
pub fn pickFromPipe(
    a: std.mem.Allocator,
    io: std.Io,
    candidates: []const project_candidates.Candidate,
) !?Selection {
    // Spawn fzf with stdin piped (we write candidates) and stdout piped (we
    // read selection). stderr stays inherited so fzf draws to the terminal.
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{
            "fzf",
            "--with-nth=1",
            "--delimiter=\t",
            "--prompt=project> ",
            "--height=40%",
        },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    // Write candidates to fzf's stdin, then close.
    {
        var buf: [4096]u8 = undefined;
        var w = child.stdin.?.writerStreaming(io, &buf);
        for (candidates) |c| {
            try w.interface.print("{s}\t{s}\n", .{ c.name, c.path });
        }
        try w.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
    }

    // Read one line of stdout (the selected entry).
    var out_buf: [4096]u8 = undefined;
    var r_buf: [4096]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &r_buf);
    const n = r.interface.readSliceShort(&out_buf) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    const text = std.mem.trimRight(u8, out_buf[0..n], "\r\n");

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    if (text.len == 0) return null;

    // Parse "name\tpath"
    const tab = std.mem.indexOfScalar(u8, text, '\t') orelse return null;
    return .{
        .name = try a.dupe(u8, text[0..tab]),
        .path = try a.dupe(u8, text[tab + 1 ..]),
    };
}
