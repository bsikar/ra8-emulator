//! The board's e-paper panel in a snapshot (RA8EMU-669): SPI protocol
//! state, register file, VCOM, load window, display arguments, busy film,
//! counters, the planes' geometry, and both pixel planes, as one `panel`
//! section.
//!
//! Each plane is width, height, byte count, then its pixel bytes. Not
//! saved, because they are wiring: `refresh_hook`, `refresh_log_hook`, and
//! `event_hook` callbacks, plus the planes' `allocator`. A load keeps the target's.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{ Missing, OutOfMemory };

const wiring = .{ "planes", "refresh_hook", "refresh_log_hook", "event_hook" };
const buffers = .{ "allocator", "image", "glass", "obs" };
const max_side: u16 = 4096;

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try writePayload(&counter.writer, board.panel);
    try file.writeSectionHeader(writer, .panel, counter.fullCount());
    try writePayload(writer, board.panel);
}

pub fn writePayload(writer: anytype, panel: anytype) !void {
    try fields.writeExcept(writer, panel, wiring);
    try fields.writeExcept(writer, panel.planes, buffers);
    inline for (.{ panel.planes.image, panel.planes.glass }) |plane| {
        try fields.write(writer, plane.width);
        try fields.write(writer, plane.height);
        try fields.write(writer, @as(u32, @intCast(plane.pixels.len)));
        try writer.writeAll(plane.pixels);
    }
}

const Raw = struct { width: u16, height: u16, pixels: []const u8 };

fn readPlane(cursor: *fields.Cursor) fields.Error!Raw {
    const width = try fields.read(u16, cursor);
    const height = try fields.read(u16, cursor);
    const len = try fields.read(u32, cursor);
    if (len > cursor.bytes.len - cursor.at) return error.Truncated;
    const pixels = cursor.bytes[cursor.at..][0..len];
    cursor.at += len;
    return .{ .width = width, .height = height, .pixels = pixels };
}

/// All or nothing: both new planes are built with the target's allocator
/// before the panel changes, and the old ones are freed only after.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .panel) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    try readPayload(&board.panel, &cursor);
}

/// Read only into caller-owned detached storage. Hooks remain the target's.
pub fn readPayload(panel: anytype, cursor: *fields.Cursor) Error!void {
    var copy = panel.*;
    try fields.readOver(cursor, &copy, wiring);
    try fields.readOver(cursor, &copy.planes, buffers);
    const image = try readPlane(cursor);
    const glass = try readPlane(cursor);
    if (!cursor.done() or !fits(copy, image, glass)) return Error.BadValue;
    const allocator = panel.planes.allocator;
    copy.planes.image = try build(@TypeOf(copy.planes.image), allocator, image);
    errdefer if (copy.planes.image.pixels.len != 0) allocator.free(copy.planes.image.pixels);
    copy.planes.glass = try build(@TypeOf(copy.planes.glass), allocator, glass);
    panel.planes.deinit();
    panel.* = copy;
    // The planes the load built record for whoever owns the panel now.
    panel.planes.image.obs = panel.planes.obs;
    panel.planes.glass.obs = panel.planes.obs;
}

fn fits(panel: anytype, image: Raw, glass: Raw) bool {
    const shape = panel.planes.geometry;
    if (shape.width == 0 or shape.height == 0 or shape.width > max_side or shape.height > max_side) return false;
    if (panel.register_count > panel.registers.len or panel.burst.len > panel.burst.buf.len or panel.burst.pos > panel.burst.len) return false;
    // During a partial new header, load_left still belongs to the old header.
    if (panel.command == .load_area and panel.data_index >= @import("wire.zig").arg.load_first_pixel) {
        if (panel.load_left > @as(u32, panel.load_width) * panel.load_height) return false;
        if (panel.load_left != 0 and panel.load_width == 0) return false;
        if (panel.loaded_pixels > @as(u32, panel.load_width) * panel.load_height) return false;
    }
    if (panel.pixels_per_word != 2 and panel.pixels_per_word != 4 and panel.pixels_per_word != 5 and panel.pixels_per_word != 8) return false;
    if ((image.pixels.len == 0) != (glass.pixels.len == 0)) return false;
    return planeFits(shape, image) and planeFits(shape, glass);
}

fn planeFits(shape: anytype, plane: Raw) bool {
    if (plane.pixels.len == 0) return plane.width == 0 and plane.height == 0;
    if (plane.width != shape.width or plane.height != shape.height) return false;
    return plane.pixels.len == @as(usize, plane.width) * plane.height;
}

fn build(comptime Buffer: type, allocator: std.mem.Allocator, raw: Raw) error{OutOfMemory}!Buffer {
    if (raw.pixels.len == 0) return .{};
    const pixels = try allocator.dupe(u8, raw.pixels);
    return .{ .width = raw.width, .height = raw.height, .pixels = pixels };
}
