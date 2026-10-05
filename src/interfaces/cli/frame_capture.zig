//! Capture buffer for the report-side panel scan.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;

pub const FrameCapture = struct {
    allocator: std.mem.Allocator,
    pixels: []u32,
    width: u32,
    height: u32,
    before: u32,

    pub fn init(allocator: std.mem.Allocator, board: *Board) !?FrameCapture {
        const width = board.display.panelWidth();
        const height = board.display.panelHeight();
        if (width == 0 or height == 0) return null;
        const count = std.math.mul(usize, width, height) catch return error.BadShape;
        const pixels = try allocator.alloc(u32, count);
        @memset(pixels, 0);
        board.display.output.capture = .{ .pixels = pixels, .width = width, .height = height };
        return .{ .allocator = allocator, .pixels = pixels, .width = width, .height = height, .before = board.display.system.frames };
    }

    pub fn deinit(self: *FrameCapture, board: *Board) void {
        board.display.output.capture = null;
        self.allocator.free(self.pixels);
    }

    pub fn finish(self: *FrameCapture, board: *Board, sequence: anytype) !void {
        defer board.display.output.capture = null;
        if (board.display.system.frames == self.before) _ = board.display.scanOut();
        if (board.display.system.frames != self.before)
            try sequence.record(self.width, self.height, self.pixels, board.time.base.now());
    }
};
