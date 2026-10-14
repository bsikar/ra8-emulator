//! The report-side handle for an already armed frame sequence.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const frame_args = @import("args.zig");
const out = @import("out.zig");
const Armed = out.Armed;

pub const Run = struct {
    armed: ?*Armed,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, board: *Board, path: ?[]const u8, every: usize) !Run {
        const armed = Armed.of(board) orelse try Armed.arm(allocator, io, board, path, every) orelse return .{ .armed = null };
        _ = try armed.fit();
        return .{ .armed = armed };
    }

    pub fn initForCli(allocator: std.mem.Allocator, io: std.Io, board: *Board, options: frame_args.Options) !Run {
        const armed = Armed.of(board) orelse try Armed.armForCli(allocator, io, board, options) orelse return .{ .armed = null };
        _ = try armed.fit();
        return .{ .armed = armed };
    }

    pub fn finish(self: *Run, board: *Board) !void {
        _ = board;
        if (self.armed) |armed| try armed.finish();
    }

    pub fn deinit(self: *Run, board: *Board) void {
        _ = board;
        if (self.armed) |armed| armed.deinit();
    }
};
