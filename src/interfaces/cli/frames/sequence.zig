//! Sample, deduplicate and write numbered panel frames with emulated timestamps.
const std = @import("std");

const gif_out = @import("../gif_out.zig");
const video_out = @import("../video_out.zig");

pub const Sequence = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    owns_directory: bool,
    index: ?std.Io.File,
    gif_path: ?[]const u8,
    gif_writer: ?gif_out.Writer = null,
    video_writer: ?video_out.Writer = null,
    every: usize,
    scanned: usize = 0,
    written: usize = 0,
    previous: ?[]u32 = null,
    previous_width: u32 = 0,
    previous_height: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, every: usize) !Sequence {
        return initOutputs(allocator, io, path, null, every);
    }

    pub fn initOutputs(
        allocator: std.mem.Allocator,
        io: std.Io,
        frames_path: ?[]const u8,
        gif_path: ?[]const u8,
        every: usize,
    ) !Sequence {
        return initAll(allocator, io, frames_path, gif_path, null, every);
    }

    pub fn initAll(
        allocator: std.mem.Allocator,
        io: std.Io,
        frames_path: ?[]const u8,
        gif_path: ?[]const u8,
        video_path: ?[]const u8,
        every: usize,
    ) !Sequence {
        if (every == 0) return error.BadInterval;
        if (frames_path == null and gif_path == null and video_path == null) return error.NoOutput;
        var directory = std.Io.Dir.cwd();
        var owns_directory = false;
        var index: ?std.Io.File = null;
        errdefer if (owns_directory) directory.close(io);
        if (frames_path) |path| {
            try std.Io.Dir.cwd().createDirPath(io, path);
            directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
            owns_directory = true;
            var entries = directory.iterate();
            while (try entries.next(io)) |entry| {
                if (isFrameName(entry.name)) try directory.deleteFile(io, entry.name);
            }
            index = try directory.createFile(io, "frames.txt", .{});
        }
        const video_writer = if (video_path) |path| try video_out.Writer.init(allocator, io, path) else null;
        return .{
            .allocator = allocator,
            .io = io,
            .directory = directory,
            .owns_directory = owns_directory,
            .index = index,
            .gif_path = gif_path,
            .video_writer = video_writer,
            .every = every,
        };
    }

    fn isFrameName(name: []const u8) bool {
        if (name.len != 15 or
            !std.mem.startsWith(u8, name, "frame_") or
            !std.mem.endsWith(u8, name, ".ppm")) return false;
        for (name[6..11]) |digit| if (!std.ascii.isDigit(digit)) return false;
        return true;
    }

    pub fn deinit(self: *Sequence) void {
        if (self.previous) |pixels| self.allocator.free(pixels);
        if (self.gif_writer) |*writer| writer.deinit();
        if (self.video_writer) |*writer| writer.deinit();
        if (self.index) |file| file.close(self.io);
        if (self.owns_directory) self.directory.close(self.io);
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
            if (self.gif_writer == null) self.gif_writer = try gif_out.Writer.init(
                self.allocator,
                self.io,
                path,
                width,
                height,
            );
            try self.gif_writer.?.record(width, height, pixels, when);
        }
        if (self.index != null) {
            try self.write(width, height, pixels);
            var line: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(&line, "frame_{d:0>5}.ppm {d}\n", .{ self.written, when });
            try self.index.?.writeStreamingAll(self.io, text);
        }
        self.written += 1;
    }

    pub fn recordVideo(self: *Sequence, width: u32, height: u32, pixels: []const u32, when: u64) !void {
        if (self.video_writer) |*writer| try writer.record(width, height, pixels, when);
    }

    pub fn holdVideoUntil(self: *Sequence, when: u64) !void {
        if (self.video_writer) |*writer| try writer.holdUntil(when);
    }

    pub fn finish(self: *Sequence) !void {
        if (self.gif_writer) |*writer| try writer.finish();
        if (self.video_writer) |*writer| try writer.finish();
    }

    fn write(self: *Sequence, width: u32, height: u32, pixels: []const u32) !void {
        const name = try std.fmt.allocPrint(self.allocator, "frame_{d:0>5}.ppm", .{self.written});
        defer self.allocator.free(name);
        var file = try self.directory.createFile(self.io, name, .{});
        defer file.close(self.io);
        var buffer: [4096]u8 = undefined;
        var buffered = file.writerStreaming(self.io, &buffer);
        const out = &buffered.interface;
        try out.print("P6\n{d} {d}\n255\n", .{ width, height });
        for (pixels) |pixel| {
            try out.writeByte(@truncate(pixel >> 16));
            try out.writeByte(@truncate(pixel >> 8));
            try out.writeByte(@truncate(pixel));
        }
        try out.flush();
    }
};
