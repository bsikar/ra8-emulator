//! Numbered P6 frames for `--frames-out`. GLCDC frames arrive after scans;
//! e-ink frames arrive after glass refreshes. Sampling and duplicate
//! suppression are shared, and frames.txt records emulated time in ns.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const frame_args = @import("frames_args.zig");
const eink = @import("../../periph/eink/eink.zig");
const eink_wire = @import("../../periph/eink/eink_wire.zig");
const gif = @import("gif.zig");

pub const Sequence = struct {
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    owns_directory: bool,
    index: ?std.fs.File,
    gif_path: ?[]const u8,
    gif_writer: ?gif.Writer = null,
    every: usize,
    scanned: usize = 0,
    written: usize = 0,
    previous: ?[]u32 = null,
    previous_width: u32 = 0,
    previous_height: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, every: usize) !Sequence {
        return initOutputs(allocator, path, null, every);
    }

    pub fn initOutputs(allocator: std.mem.Allocator, frames_path: ?[]const u8, gif_path: ?[]const u8, every: usize) !Sequence {
        if (every == 0) return error.BadInterval;
        if (frames_path == null and gif_path == null) return error.NoOutput;
        var directory = std.fs.cwd();
        var owns_directory = false;
        var index: ?std.fs.File = null;
        errdefer if (owns_directory) directory.close();
        if (frames_path) |path| {
            try std.fs.cwd().makePath(path);
            directory = try std.fs.cwd().openDir(path, .{ .iterate = true });
            owns_directory = true;
            var entries = directory.iterate();
            while (try entries.next()) |entry| {
                if (isFrameName(entry.name)) try directory.deleteFile(entry.name);
            }
            index = try directory.createFile("frames.txt", .{});
        }
        return .{
            .allocator = allocator,
            .directory = directory,
            .owns_directory = owns_directory,
            .index = index,
            .gif_path = gif_path,
            .every = every,
        };
    }

    fn isFrameName(name: []const u8) bool {
        if (name.len != 15 or !std.mem.startsWith(u8, name, "frame_") or !std.mem.endsWith(u8, name, ".ppm")) return false;
        for (name[6..11]) |digit| if (!std.ascii.isDigit(digit)) return false;
        return true;
    }

    pub fn deinit(self: *Sequence) void {
        if (self.previous) |pixels| self.allocator.free(pixels);
        if (self.gif_writer) |*writer| writer.deinit();
        if (self.index) |file| file.close();
        if (self.owns_directory) self.directory.close();
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
        if (self.gif_path) |path| {
            if (self.gif_writer == null) self.gif_writer = try gif.Writer.init(self.allocator, path, width, height);
            try self.gif_writer.?.record(width, height, pixels, when);
        }
        if (self.index != null) {
            try self.write(width, height, pixels);
            try self.index.?.writer().print("frame_{d:0>5}.ppm {d}\n", .{ self.written, when });
        }
        self.written += 1;
    }

    pub fn finish(self: *Sequence) !void {
        if (self.gif_writer) |*writer| try writer.finish();
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

/// --frames-out armed before the run (RA8EMU-573). It installs a Vsync on
/// the GLCDC output stage, so each frame period the board boundary scans the
/// panel and the frame is kept with its emulated time. The end-of-run report
/// scan is kept too, unless it repeats the last frame.
pub const Armed = struct {
    allocator: std.mem.Allocator,
    board: *Board,
    sequence: Sequence,
    capture: ?FrameCapture = null,
    /// The first error an in-run frame hit; the boundary cannot return one.
    failed: ?anyerror = null,
    eink_panel: ?*eink.Panel = null,
    eink_pixels: ?[]u32 = null,

    /// Null when both sequence outputs are off. Call after board.attach:
    /// attaching the GLCDC rebuilds its output stage, which would drop Vsync.
    pub fn arm(allocator: std.mem.Allocator, board: *Board, path: ?[]const u8, every: usize) !?*Armed {
        return armOutputs(allocator, board, path, null, every);
    }

    pub fn armOutputs(allocator: std.mem.Allocator, board: *Board, frames_path: ?[]const u8, gif_path: ?[]const u8, every: usize) !?*Armed {
        if (frames_path == null and gif_path == null) return null;
        const self = try allocator.create(Armed);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .board = board,
            .sequence = try Sequence.initOutputs(allocator, frames_path, gif_path, every),
        };
        errdefer self.sequence.deinit();
        if (board.asks.attached_eink) |panel| {
            self.eink_panel = panel;
            self.eink_pixels = try allocator.alloc(u32, panel.glass_buffer.pixels.len);
            panel.refresh_hook = .{ .context = self, .refreshFn = onEinkRefresh };
        }
        board.display.output.vsync = .{ .sink = .{ .context = self, .frame = onFrame } };
        return self;
    }

    /// The run armed on this board, if any.
    pub fn of(board: *Board) ?*Armed {
        const vsync = board.display.output.vsync orelse return null;
        if (vsync.sink.frame != onFrame) return null;
        return @ptrCast(@alignCast(vsync.sink.context));
    }

    fn onFrame(context: *anyopaque, when: u64) void {
        const self: *Armed = @ptrCast(@alignCast(context));
        self.frameAt(when) catch |err| {
            if (self.failed == null) self.failed = err;
        };
    }

    fn frameAt(self: *Armed, when: u64) !void {
        if (self.eink_panel != null) return;
        const capture = (try self.fit()) orelse return;
        if (self.board.display.scanOut() == null) return;
        try self.sequence.record(capture.width, capture.height, capture.pixels, when);
        capture.before = self.board.display.system.frames;
    }

    fn onEinkRefresh(context: *anyopaque) void {
        const self: *Armed = @ptrCast(@alignCast(context));
        const panel = self.eink_panel.?;
        const pixels = self.eink_pixels.?;
        for (panel.glass_buffer.pixels, pixels) |gray, *pixel| {
            pixel.* = 0xFF00_0000 | (@as(u32, gray) << 16) | (@as(u32, gray) << 8) | gray;
        }
        self.sequence.record(eink_wire.panel.width, eink_wire.panel.height, pixels, self.board.time.base.now()) catch |err| {
            if (self.failed == null) self.failed = err;
        };
    }

    /// The capture buffer, sized to the panel as the firmware has it now.
    pub fn fit(self: *Armed) !?*FrameCapture {
        if (self.eink_panel != null) return null;
        if (self.capture) |*capture| {
            const same = capture.width == self.board.display.panelWidth() and
                capture.height == self.board.display.panelHeight();
            if (same) {
                self.board.display.output.capture = .{ .pixels = capture.pixels, .width = capture.width, .height = capture.height };
                return capture;
            }
            capture.deinit(self.board);
            self.capture = null;
        }
        self.capture = try FrameCapture.init(self.allocator, self.board);
        return if (self.capture) |*capture| capture else null;
    }

    pub fn finish(self: *Armed) !void {
        if (self.failed) |err| return err;
        if (self.capture) |*capture| try capture.finish(self.board, &self.sequence);
        try self.sequence.finish();
    }

    pub fn deinit(self: *Armed) void {
        self.board.display.output.vsync = null;
        if (self.eink_panel) |panel| {
            if (panel.refresh_hook) |hook| {
                if (hook.context == @as(*anyopaque, @ptrCast(self))) panel.refresh_hook = null;
            }
        }
        if (self.eink_pixels) |pixels| self.allocator.free(pixels);
        if (self.capture) |*capture| capture.deinit(self.board);
        self.sequence.deinit();
        self.allocator.destroy(self);
    }
};

/// Report-side handle for an already armed frame sequence.
pub const Run = struct {
    armed: ?*Armed,

    pub fn init(allocator: std.mem.Allocator, board: *Board, path: ?[]const u8, every: usize) !Run {
        const armed = Armed.of(board) orelse try Armed.arm(allocator, board, path, every) orelse return .{ .armed = null };
        _ = try armed.fit();
        return .{ .armed = armed };
    }

    pub fn initForCli(allocator: std.mem.Allocator, board: *Board, options: frame_args.Options) !Run {
        const armed = Armed.of(board) orelse try Armed.armOutputs(
            allocator,
            board,
            options.frames_out,
            options.gif_out,
            options.frames_every,
        ) orelse return .{ .armed = null };
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
