//! Constant-rate grayscale Y4M output, optionally piped into ffmpeg for MP4.
const std = @import("std");

const fps: u64 = 10;
const ns_per_second: u64 = 1_000_000_000;

pub const Writer = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: Mode,
    output: ?Output = null,
    width: u32 = 0,
    height: u32 = 0,
    origin: u64 = 0,
    last_when: u64 = 0,
    written: u64 = 0,
    pending: ?[]u32 = null,
    finished: bool = false,

    const Mode = enum { y4m, mp4 };
    const Output = union(enum) { file: std.fs.File, child: std.process.Child };

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Writer {
        const mode: Mode = if (std.mem.endsWith(u8, path, ".y4m")) .y4m else if (std.mem.endsWith(u8, path, ".mp4")) .mp4 else return error.BadVideoExtension;
        if (mode == .mp4) requireFfmpeg(allocator) catch |err| {
            std.debug.print("--video-out {s}: ffmpeg unavailable; use a .y4m path for built-in output\n", .{path});
            return err;
        };
        return .{ .allocator = allocator, .path = try allocator.dupe(u8, path), .mode = mode };
    }

    fn requireFfmpeg(allocator: std.mem.Allocator) !void {
        const result = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "ffmpeg", "-version" }, .max_output_bytes = 16 * 1024 }) catch return error.FfmpegNotFound;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) return error.FfmpegNotFound;
    }

    fn start(self: *Writer, width: u32, height: u32) !void {
        self.width = width;
        self.height = height;
        if (self.mode == .y4m) {
            const file = try std.fs.cwd().createFile(self.path, .{ .truncate = true });
            self.output = .{ .file = file };
        } else {
            var child = std.process.Child.init(&.{ "ffmpeg", "-y", "-v", "error", "-f", "yuv4mpegpipe", "-i", "-", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "12", "-movflags", "+faststart", self.path }, self.allocator);
            child.stdin_behavior = .Pipe;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            try child.spawn();
            self.output = .{ .child = child };
        }
        try self.writeFmt("YUV4MPEG2 W{d} H{d} F10:1 Ip A1:1 Cmono\n", .{ width, height });
    }

    pub fn record(self: *Writer, width: u32, height: u32, pixels: []const u32, when: u64) !void {
        if (width == 0 or height == 0 or pixels.len != @as(usize, width) * height) return error.BadShape;
        if (self.width == 0) {
            try self.start(width, height);
            self.origin = when;
            self.last_when = when;
            self.pending = try self.allocator.dupe(u32, pixels);
            try self.emit(pixels);
            self.written = 1;
            return;
        }
        if (width != self.width or height != self.height) return error.BadShape;
        self.last_when = when;
        if (self.pending) |pending| {
            const target = std.math.mul(u64, when -| self.origin, fps) catch return error.BadDuration;
            const target_frames = target / ns_per_second;
            while (self.written < target_frames) {
                try self.emit(pending);
                self.written += 1;
            }
            if (same(pending, pixels)) return;
            self.allocator.free(pending);
        }
        self.pending = try self.allocator.dupe(u32, pixels);
    }

    pub fn holdUntil(self: *Writer, when: u64) !void {
        const pending = self.pending orelse return;
        try self.record(self.width, self.height, pending, when);
    }

    fn same(left: []const u32, right: []const u32) bool {
        if (left.len != right.len) return false;
        for (left, right) |a, b| if (a != b) return false;
        return true;
    }

    fn emit(self: *Writer, pixels: []const u32) !void {
        try self.writeAll("FRAME\n");
        for (pixels) |pixel| {
            const red: u32 = pixel >> 16 & 0xFF;
            const green: u32 = pixel >> 8 & 0xFF;
            const blue: u32 = pixel & 0xFF;
            try self.writeByte(@intCast((77 * red + 150 * green + 29 * blue + 128) >> 8));
        }
    }

    fn writeAll(self: *Writer, bytes: []const u8) !void {
        switch (self.output.?) {
            .file => |file| try file.writeAll(bytes),
            .child => |*child| try child.stdin.?.writeAll(bytes),
        }
    }

    fn writeByte(self: *Writer, byte: u8) !void {
        switch (self.output.?) {
            .file => |file| try file.writeAll(&.{byte}),
            .child => |*child| try child.stdin.?.writeAll(&.{byte}),
        }
    }

    fn writeFmt(self: *Writer, comptime format: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(line);
        try self.writeAll(line);
    }

    pub fn finish(self: *Writer) !void {
        const pending = self.pending orelse return;
        const elapsed_frames = @as(u64, @intCast((self.last_when -| self.origin) / (ns_per_second / fps)));
        const total = elapsed_frames + fps;
        while (self.written < total) {
            try self.emit(pending);
            self.written += 1;
        }
        self.allocator.free(pending);
        self.pending = null;
        switch (self.output.?) {
            .file => |file| {
                try file.sync();
                file.close();
            },
            .child => |*child| {
                child.stdin.?.close();
                child.stdin = null;
                const term = try child.wait();
                if (term != .Exited or term.Exited != 0) return error.FfmpegFailed;
            },
        }
        self.finished = true;
    }

    pub fn deinit(self: *Writer) void {
        if (self.pending) |pending| self.allocator.free(pending);
        if (!self.finished) if (self.output) |*output| switch (output.*) {
            .file => |file| file.close(),
            .child => |*child| {
                if (child.stdin) |stdin| stdin.close();
                _ = child.kill() catch {};
            },
        };
        self.allocator.free(self.path);
    }
};
