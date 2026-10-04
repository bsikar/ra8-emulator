//! A small deterministic GIF89a writer for sampled panel frames.
const std = @import("std");

pub const lzw = @import("gif_lzw.zig");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    width: u16,
    height: u16,
    pending: ?[]u32 = null,
    pending_when: u64 = 0,
    prior_delay: u16 = 10,
    wrote: usize = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, width: u32, height: u32) !Writer {
        if (width == 0 or height == 0 or width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return error.BadShape;
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        errdefer file.close();
        var self: Writer = .{ .allocator = allocator, .file = file, .width = @intCast(width), .height = @intCast(height) };
        try self.header();
        return self;
    }

    fn word(self: *Writer, value: u16) !void {
        try self.file.writer().writeByte(@truncate(value));
        try self.file.writer().writeByte(@truncate(value >> 8));
    }

    fn header(self: *Writer) !void {
        try self.file.writer().writeAll("GIF89a");
        try self.word(self.width);
        try self.word(self.height);
        try self.file.writer().writeAll(&.{ 0xF7, 0, 0 });
        for (0..256) |index| {
            const i: u8 = @intCast(index);
            try self.file.writer().writeAll(&.{
                @intCast(@as(u16, i >> 5) * 255 / 7),
                @intCast(@as(u16, (i >> 2) & 7) * 255 / 7),
                @intCast(@as(u16, i & 3) * 255 / 3),
            });
        }
        try self.file.writer().writeAll(&.{ 0x21, 0xFF, 0x0B });
        try self.file.writer().writeAll("NETSCAPE2.0");
        try self.file.writer().writeAll(&.{ 3, 1, 0, 0, 0 });
    }

    fn delayFor(delta_ns: u64) u16 {
        const centiseconds = (delta_ns + 5_000_000) / 10_000_000;
        return @intCast(@min(@max(centiseconds, 1), std.math.maxInt(u16)));
    }

    /// The previous frame remains pending until the next timestamp establishes its delay.
    pub fn record(self: *Writer, width: u32, height: u32, pixels: []const u32, when: u64) !void {
        if (width != self.width or height != self.height or pixels.len != @as(usize, width) * height) return error.BadShape;
        if (self.pending) |previous| {
            self.prior_delay = delayFor(when -| self.pending_when);
            try self.emit(previous, self.prior_delay);
            self.allocator.free(previous);
        }
        self.pending = try self.allocator.dupe(u32, pixels);
        self.pending_when = when;
    }

    fn emit(self: *Writer, pixels: []const u32, delay: u16) !void {
        try self.file.writer().writeAll(&.{ 0x21, 0xF9, 4, 0x04 });
        try self.word(delay);
        try self.file.writer().writeAll(&.{ 0, 0, 0x2C });
        try self.word(0);
        try self.word(0);
        try self.word(self.width);
        try self.word(self.height);
        try self.file.writer().writeByte(0);
        try self.file.writer().writeByte(lzw.min_code_size);
        const indices = try self.allocator.alloc(u8, pixels.len);
        defer self.allocator.free(indices);
        for (pixels, indices) |pixel, *index| index.* = quantize(pixel);
        var compressed = std.ArrayList(u8).init(self.allocator);
        defer compressed.deinit();
        try lzw.encode(self.allocator, indices, &compressed);
        var offset: usize = 0;
        while (offset < compressed.items.len) {
            const count = @min(255, compressed.items.len - offset);
            try self.file.writer().writeByte(@intCast(count));
            try self.file.writer().writeAll(compressed.items[offset .. offset + count]);
            offset += count;
        }
        try self.file.writer().writeByte(0);
        self.wrote += 1;
    }

    /// RGB 3-3-2 index into the fixed palette written by `header`.
    fn quantize(pixel: u32) u8 {
        return @truncate((pixel >> 16 & 0xE0) | (pixel >> 11 & 0x1C) | (pixel >> 6 & 0x03));
    }

    pub fn finish(self: *Writer) !void {
        if (self.pending) |pixels| {
            try self.emit(pixels, if (self.wrote == 0) 10 else self.prior_delay);
            self.allocator.free(pixels);
            self.pending = null;
        }
        try self.file.writer().writeByte(0x3B);
        try self.file.sync();
    }

    pub fn deinit(self: *Writer) void {
        if (self.pending) |pixels| self.allocator.free(pixels);
        self.file.close();
    }
};
