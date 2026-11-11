//! Reading a run's input script into the board (RA8EMU-1092): parsed from
//! caller-supplied bytes or read through caller-provided `file_ops` (ADR 0004 D20).
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const file_ops = @import("../file_ops.zig");
const limits = @import("harness.zig").limits;

/// Parse `script_bytes` when given, or read `path` via `files`; null keeps the board's.
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    files: ?file_ops.Ops,
    board: *Board,
    path: ?[]const u8,
    script_bytes: ?[]const u8,
) !void {
    if (script_bytes) |text| {
        if (text.len > limits.max_input_bytes) return error.StreamTooLong;
        return board.input_script.parse(text);
    }
    const named = path orelse return;
    const ops = files orelse return error.NoFileOps;
    const text = try ops.reader.readAlloc(io, named, allocator, limits.max_input_bytes);
    defer allocator.free(text);
    try board.input_script.parse(text);
}
