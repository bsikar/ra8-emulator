//! The board's USB side in a snapshot (RA8EMU-682): the HS host controller,
//! the FS device on the other jack and the scripted host on it, as one `usb`
//! section.
//!
//! Not saved, because it is wiring: the cable between the jacks (laid by
//! `loopBack`; it holds a device pointer), the usbip bridge hook, the HS
//! transfer's far-end pointer, the echo device's pointer to the stick and the MSC
//! disk, a host attachment like an SD
//! image. A load keeps the target's.
//!
//! The MSC target's data and sink cursors point into the disk, its scratch
//! reply or the constant INQUIRY data, so they are saved as where, offset
//! and length, and rebuilt over the target's own buffers.
const std = @import("std");
const file = @import("../../snapshot/file.zig");
const fields = @import("../../snapshot/fields.zig");
const msc = @import("../../components/usb_stick/stick.zig");

pub const Error = file.Error || fields.Error || error{Missing};

const skip: []const []const u8 = &.{ "host.xfer.far", "echo.storage", "cable", "bridge", "stick" };
const storage_skip: []const []const u8 = &.{ "disk", "data", "sink" };

const Where = enum(u8) { none, disk, scratch, inquiry };

/// A cursor as where it points, how far in and how long.
const Span = struct { where: Where = .none, offset: u32 = 0, len: u32 = 0 };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, board);
    try file.writeSectionHeader(writer, .usb, counter.fullCount());
    try body(writer, board);
}

fn body(writer: anytype, board: anytype) !void {
    const storage = &board.usb.stick;
    try fields.writeExcept(writer, board.usb, skip);
    try fields.writeExcept(writer, storage.*, storage_skip);
    try fields.write(writer, try locate(storage, storage.data));
    try fields.write(writer, try locate(storage, storage.sink));
}

/// All or nothing: the section is read over a copy, both cursors are
/// checked against the target's buffers, and only then does the board change.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .usb) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var usb = board.usb;
    try fields.readOver(&cursor, &usb, skip);
    var storage = board.usb.stick;
    try fields.readOver(&cursor, &storage, storage_skip);
    const data = try fields.read(Span, &cursor);
    const sink = try fields.read(Span, &cursor);
    if (!cursor.done()) return Error.BadValue;
    try check(&storage, data);
    if (sink.where != .none and sink.where != .disk) return Error.BadValue;
    try check(&storage, sink);
    board.usb = usb;
    const live = &board.usb.stick;
    live.* = storage;
    live.data = slice(live, data);
    live.sink = if (sink.where == .disk) live.disk[sink.offset..][0..sink.len] else &.{};
}

fn base(storage: anytype, where: Where) []const u8 {
    return switch (where) {
        .none => &.{},
        .disk => storage.disk,
        .scratch => &storage.scratch,
        .inquiry => &msc.inquiry_data,
    };
}

fn locate(storage: anytype, cursor: []const u8) error{Stray}!Span {
    if (cursor.len == 0) return .{};
    const at = @intFromPtr(cursor.ptr);
    inline for (.{ Where.disk, Where.scratch, Where.inquiry }) |where| {
        const within = base(storage, where);
        const lo = @intFromPtr(within.ptr);
        if (at >= lo and at + cursor.len <= lo + within.len)
            return .{ .where = where, .offset = @intCast(at - lo), .len = @intCast(cursor.len) };
    }
    return error.Stray;
}

fn check(storage: anytype, span: Span) Error!void {
    if (span.where == .none) {
        if (span.offset != 0 or span.len != 0) return Error.BadValue;
        return;
    }
    const within = base(storage, span.where);
    if (span.len == 0 or span.offset > within.len or span.len > within.len - span.offset) return Error.BadValue;
}

fn slice(storage: anytype, span: Span) []const u8 {
    return base(storage, span.where)[span.offset..][0..span.len];
}
