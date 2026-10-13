//! Video and animated GIF output writer for GUI recordings (RA8EMU-1120).
const std = @import("std");
const gif = @import("ra8_render").gif;
const raster = @import("ra8_render").raster;
const draw_list = @import("ra8_render").draw_list;

const Color = draw_list.Color;
const Framebuffer = raster.Framebuffer;

pub const Format = enum {
    gif,
    mp4,
    y4m,

    pub fn fromPath(path: []const u8) ?Format {
        if (std.mem.endsWith(u8, path, ".gif")) return .gif;
        if (std.mem.endsWith(u8, path, ".mp4")) return .mp4;
        if (std.mem.endsWith(u8, path, ".y4m")) return .y4m;
        return null;
    }
};

pub const Error = error{
    BadFormat,
    FfmpegNotFound,
    SpawnFailed,
    IoError,
    OutOfMemory,
    BadShape,
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    format: Format,
    fps: u32,
    width: u32 = 0,
    height: u32 = 0,
    header_written: bool = false,

    // GIF backend
    gif_file: ?std.Io.File = null,
    gif_sink: ?*std.Io.File.Writer = null,
    gif_buf: ?[]u8 = null,
    gif_encoder: ?gif.Encoder = null,

    // Direct Y4M backend
    y4m_file: ?std.Io.File = null,
    y4m_sink: ?*std.Io.File.Writer = null,
    y4m_buf: ?[]u8 = null,

    // FFmpeg MP4 backend
    ffmpeg_child: ?std.process.Child = null,
    ffmpeg_sink: ?*std.Io.File.Writer = null,
    ffmpeg_buf: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, fps: u32) Error!Writer {
        const format = Format.fromPath(path) orelse return error.BadFormat;
        return .{
            .allocator = allocator,
            .io = io,
            .path = path,
            .format = format,
            .fps = if (fps == 0) 30 else fps,
        };
    }

    pub fn record(self: *Writer, frame: *const Framebuffer, when_ns: u64) !void {
        if (!self.header_written) {
            try self.start(frame.width, frame.height);
        }
        switch (self.format) {
            .gif => try self.recordGif(frame, when_ns),
            .y4m => try self.recordY4m(frame, &self.y4m_sink.?.interface),
            .mp4 => try self.recordY4m(frame, &self.ffmpeg_sink.?.interface),
        }
    }

    pub fn finish(self: *Writer) !void {
        switch (self.format) {
            .gif => {
                if (self.gif_encoder) |*enc| try enc.finish();
                if (self.gif_sink) |sink| try sink.interface.flush();
                if (self.gif_file) |f| try f.sync(self.io);
            },
            .y4m => {
                if (self.y4m_sink) |sink| try sink.interface.flush();
                if (self.y4m_file) |f| try f.sync(self.io);
            },
            .mp4 => {
                if (self.ffmpeg_sink) |sink| try sink.interface.flush();
                if (self.ffmpeg_child) |*child| {
                    if (child.stdin) |*stdin| stdin.close(self.io);
                    // EOF ends the encoder input; wait must not close it again.
                    child.stdin = null;
                    _ = child.wait(self.io) catch {};
                    self.ffmpeg_child = null;
                }
            },
        }
    }

    pub fn deinit(self: *Writer) void {
        switch (self.format) {
            .gif => {
                if (self.gif_encoder) |*enc| enc.deinit();
                if (self.gif_sink) |sink| self.allocator.destroy(sink);
                if (self.gif_buf) |buf| self.allocator.free(buf);
                if (self.gif_file) |f| f.close(self.io);
            },
            .y4m => {
                if (self.y4m_sink) |sink| self.allocator.destroy(sink);
                if (self.y4m_buf) |buf| self.allocator.free(buf);
                if (self.y4m_file) |f| f.close(self.io);
            },
            .mp4 => {
                if (self.ffmpeg_sink) |sink| self.allocator.destroy(sink);
                if (self.ffmpeg_buf) |buf| self.allocator.free(buf);
                if (self.ffmpeg_child) |*child| {
                    if (child.stdin) |*stdin| stdin.close(self.io);
                    child.stdin = null;
                    _ = child.wait(self.io) catch {};
                }
            },
        }
    }

    fn start(self: *Writer, width: u32, height: u32) !void {
        self.width = width;
        self.height = height;
        self.header_written = true;

        switch (self.format) {
            .gif => try self.startGif(width, height),
            .y4m => try self.startY4m(width, height),
            .mp4 => try self.startMp4(width, height),
        }
    }

    fn startGif(self: *Writer, width: u32, height: u32) !void {
        if (!gif.fits(width, height)) return error.BadShape;
        const file = try std.Io.Dir.cwd().createFile(self.io, self.path, .{ .truncate = true });
        self.gif_file = file;
        const buffer = try self.allocator.alloc(u8, 16384);
        self.gif_buf = buffer;
        const sink = try self.allocator.create(std.Io.File.Writer);
        sink.* = file.writerStreaming(self.io, buffer);
        self.gif_sink = sink;
        self.gif_encoder = try gif.Encoder.init(self.allocator, &sink.interface, width, height);
    }

    fn startY4m(self: *Writer, width: u32, height: u32) !void {
        const file = try std.Io.Dir.cwd().createFile(self.io, self.path, .{ .truncate = true });
        self.y4m_file = file;
        const buffer = try self.allocator.alloc(u8, 16384);
        self.y4m_buf = buffer;
        const sink = try self.allocator.create(std.Io.File.Writer);
        sink.* = file.writerStreaming(self.io, buffer);
        self.y4m_sink = sink;
        try self.writeY4mHeader(&sink.interface, width, height);
    }

    fn startMp4(self: *Writer, width: u32, height: u32) !void {
        var child = std.process.spawn(self.io, .{
            .argv = &.{
                "ffmpeg",     "-y",
                "-v",         "error",
                "-f",         "yuv4mpegpipe",
                "-i",         "-",
                "-an",        "-c:v",
                "libx264",    "-pix_fmt",
                "yuv420p",    "-crf",
                "18",         "-movflags",
                "+faststart", self.path,
            },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.FfmpegNotFound,
            else => return error.SpawnFailed,
        };
        self.ffmpeg_child = child;
        const buffer = try self.allocator.alloc(u8, 16384);
        self.ffmpeg_buf = buffer;
        const sink = try self.allocator.create(std.Io.File.Writer);
        sink.* = child.stdin.?.writerStreaming(self.io, buffer);
        self.ffmpeg_sink = sink;
        try self.writeY4mHeader(&sink.interface, width, height);
    }

    fn writeY4mHeader(self: *Writer, out: *std.Io.Writer, width: u32, height: u32) !void {
        const enc_w = width & ~@as(u32, 1);
        const enc_h = height & ~@as(u32, 1);
        var hdr_buf: [128]u8 = undefined;
        const header = try std.fmt.bufPrint(&hdr_buf, "YUV4MPEG2 W{d} H{d} F{d}:1 Ip A1:1 C420jpeg\n", .{ enc_w, enc_h, self.fps });
        try out.writeAll(header);
    }

    fn recordGif(self: *Writer, frame: *const Framebuffer, when_ns: u64) !void {
        const enc = &(self.gif_encoder orelse return error.BadFormat);
        const u32_pixels = try self.allocator.alloc(u32, frame.pixels.len);
        defer self.allocator.free(u32_pixels);
        for (frame.pixels, u32_pixels) |c, *out| {
            out.* = (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | @as(u32, c.b);
        }
        try enc.record(frame.width, frame.height, u32_pixels, when_ns);
    }

    fn recordY4m(self: *Writer, frame: *const Framebuffer, out: *std.Io.Writer) !void {
        _ = self;
        try out.writeAll("FRAME\n");
        const enc_w = frame.width & ~@as(u32, 1);
        const enc_h = frame.height & ~@as(u32, 1);

        // Y plane
        var y: usize = 0;
        while (y < enc_h) : (y += 1) {
            const row = frame.pixels[y * frame.width .. y * frame.width + enc_w];
            for (row) |c| {
                const r: u32 = c.r;
                const g: u32 = c.g;
                const b: u32 = c.b;
                const y_val: u8 = @intCast(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
                try out.writeByte(y_val);
            }
        }

        // Cb (U) plane and Cr (V) plane
        const uv_w = enc_w / 2;
        const uv_h = enc_h / 2;

        // Write Cb
        var cy: usize = 0;
        while (cy < uv_h) : (cy += 1) {
            const y0 = cy * 2;
            const y1 = y0 + 1;
            var cx: usize = 0;
            while (cx < uv_w) : (cx += 1) {
                const x0 = cx * 2;
                const x1 = x0 + 1;
                const c00 = frame.pixels[y0 * frame.width + x0];
                const c01 = frame.pixels[y0 * frame.width + x1];
                const c10 = frame.pixels[y1 * frame.width + x0];
                const c11 = frame.pixels[y1 * frame.width + x1];
                const r: u32 = (@as(u32, c00.r) + c01.r + c10.r + c11.r) >> 2;
                const g: u32 = (@as(u32, c00.g) + c01.g + c10.g + c11.g) >> 2;
                const b: u32 = (@as(u32, c00.b) + c01.b + c10.b + c11.b) >> 2;
                const u_val: u8 = @intCast(((-38 * @as(i32, @intCast(r)) - 74 * @as(i32, @intCast(g)) + 112 * @as(i32, @intCast(b)) + 128) >> 8) + 128);
                try out.writeByte(u_val);
            }
        }

        // Write Cr
        cy = 0;
        while (cy < uv_h) : (cy += 1) {
            const y0 = cy * 2;
            const y1 = y0 + 1;
            var cx: usize = 0;
            while (cx < uv_w) : (cx += 1) {
                const x0 = cx * 2;
                const x1 = x0 + 1;
                const c00 = frame.pixels[y0 * frame.width + x0];
                const c01 = frame.pixels[y0 * frame.width + x1];
                const c10 = frame.pixels[y1 * frame.width + x0];
                const c11 = frame.pixels[y1 * frame.width + x1];
                const r: u32 = (@as(u32, c00.r) + c01.r + c10.r + c11.r) >> 2;
                const g: u32 = (@as(u32, c00.g) + c01.g + c10.g + c11.g) >> 2;
                const b: u32 = (@as(u32, c00.b) + c01.b + c10.b + c11.b) >> 2;
                const v_val: u8 = @intCast(((112 * @as(i32, @intCast(r)) - 94 * @as(i32, @intCast(g)) - 18 * @as(i32, @intCast(b)) + 128) >> 8) + 128);
                try out.writeByte(v_val);
            }
        }
    }
};
