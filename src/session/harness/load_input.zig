//! Reading a run's input script into the board (RA8EMU-1092): the one file
//! read the harness does beside the image, out so harness.zig stays short.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const limits = @import("harness.zig").limits;

/// Read `path`'s script and parse it onto the board; null keeps the board's.
pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, board: *Board, path: ?[]const u8) !void {
    const named = path orelse return;
    const text = try dir.readFileAlloc(io, named, allocator, .limited(limits.max_input_bytes));
    defer allocator.free(text);
    try board.input_script.parse(text);
}
