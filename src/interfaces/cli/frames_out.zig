//! Numbered P6 frames for `--frames-out`. Frames arrive only after a GLCDC
//! scan completed; this module handles sampling, duplicate suppression, and
//! deterministic file output. Each written frame gets a line in frames.txt
//! beside it: the file name and the emulated time it was scanned, in ns.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const frame_args = @import("frames_args.zig");

pub const Sequence = struct {
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    index: std.fs.File,
    every: usize,
    scanned: usize = 0,
    written: usize = 0,
    previous: ?[]u32 = null,
    previous_width: u32 = 0,
    previous_height: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, every: usize) !Sequence {
        if (every == 0) return error.BadInterval;
        try std.fs.cwd().makePath(path);
        var directory = try std.fs.cwd().openDir(path, .{ .iterate = true });
        errdefer directory.close();
        var entries = directory.iterate();
        while (try entries.next()) |entry| {
            if (isFrameName(entry.name)) try directory.deleteFile(entry.name);
        }
        const index = try directory.createFile("frames.txt", .{});
        return .{ .allocator = allocator, .directory = directory, .index = index, .every = every };
    }

    fn isFrameName(name: []const u8) bool {
        if (name.len != 15 or !std.mem.startsWith(u8, name, "frame_") or !std.mem.endsWith(u8, name, ".ppm")) return false;
        for (name[6..11]) |digit| if (!std.ascii.isDigit(digit)) return false;
        return true;
    }

    pub fn deinit(self: *Sequence) void {
        if (self.previous) |pixels| self.allocator.free(pixels);
        self.index.close();
        self.directory.close();
    }

    /// Record one complete ARGB8888 panel. Every Nth scan is considered,
    /// and scans identical to their immediate predecessor are suppressed.
    fn sameImage(previous: []const u32, current: []const u32) bool {
        if (previous.len != current.len) return false;
        for (previous, current) |before, after| {
            if (before & 0x00FF_FFFF != after & 0x00FF_FFFF) return false;
        }
        return true;
    }

    /// `when` is the emulated time of the scan, written to frames.txt.
    pub fn record(self: *Sequence, width: u32, height: u32, pixels: []const u32, when: u64) !void {
        const count = std.math.mul(usize, width, height) catch return error.BadShape;
        if (width == 0 or height == 0 or pixels.len != count) return error.BadShape;
        const same = if (self.previous) |previous|
            self.previous_width == width and self.previous_height == height and
                sameImage(previous, pixels)
        else
            false;
        if (self.previous) |previous| {
            if (previous.len != pixels.len) {
                self.allocator.free(previous);
                self.previous = null;
            }
        }
        if (self.previous == null) self.previous = try self.allocator.alloc(u32, pixels.len);
        @memcpy(self.previous.?, pixels);
        self.previous_width = width;
        self.previous_height = height;

        const index = self.scanned;
        self.scanned += 1;
        if (same or index % self.every != 0) return;
        try self.write(width, height, pixels);
        try self.index.writer().print("frame_{d:0>5}.ppm {d}\n", .{ self.written, when });
        self.written += 1;
    }

    fn write(self: *Sequence, width: u32, height: u32, pixels: []const u32) !void {
        const name = try std.fmt.allocPrint(self.allocator, "frame_{d:0>5}.ppm", .{self.written});
        defer self.allocator.free(name);
        var file = try self.directory.createFile(name, .{});
        defer file.close();
        var buffered = std.io.bufferedWriter(file.writer());
        const out = buffered.writer();
        try out.print("P6\n{d} {d}\n255\n", .{ width, height });
        for (pixels) |pixel| {
            try out.writeByte(@truncate(pixel >> 16));
            try out.writeByte(@truncate(pixel >> 8));
            try out.writeByte(@truncate(pixel));
        }
        try buffered.flush();
    }
};

/// Buffers the panel around the report scan, or asks for one scan after the
/// report if it did not scan. No extra scan is made when reporting already
/// completed one.
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
        return .{
            .allocator = allocator,
            .pixels = pixels,
            .width = width,
            .height = height,
            .before = board.display.system.frames,
        };
    }

    pub fn deinit(self: *FrameCapture, board: *Board) void {
        board.display.output.capture = null;
        self.allocator.free(self.pixels);
    }

    pub fn finish(self: *FrameCapture, board: *Board, sequence: *Sequence) !void {
        defer board.display.output.capture = null;
        if (board.display.system.frames == self.before) _ = board.display.scanOut();
        if (board.display.system.frames != self.before)
            try sequence.record(self.width, self.height, self.pixels, board.time.base.now());
    }
};

/// Run-scoped wiring for the CLI. A disabled run is a no-op; an enabled run
/// captures the successful report scan, asking for one only if needed.
pub const Run = struct {
    sequence: ?Sequence,
    capture: ?FrameCapture,

    pub fn init(allocator: std.mem.Allocator, board: *Board, path: ?[]const u8, every: usize) !Run {
        var sequence: ?Sequence = if (path) |directory|
            try Sequence.init(allocator, directory, every)
        else
            null;
        errdefer if (sequence) |*one| one.deinit();
        const capture = if (sequence != null) try FrameCapture.init(allocator, board) else null;
        return .{ .sequence = sequence, .capture = capture };
    }

    pub fn initForCli(allocator: std.mem.Allocator, board: *Board, options: frame_args.Options) !Run {
        return init(allocator, board, options.frames_out, options.frames_every);
    }

    pub fn finish(self: *Run, board: *Board) !void {
        if (self.capture) |*capture| try capture.finish(board, &self.sequence.?);
    }

    pub fn deinit(self: *Run, board: *Board) void {
        if (self.capture) |*capture| capture.deinit(board);
        if (self.sequence) |*sequence| sequence.deinit();
    }
};
