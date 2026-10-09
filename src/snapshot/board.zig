//! A whole board in a snapshot (RA8EMU-688): a `part` section naming the
//! part, then every board-owned section in kind order.
//!
//! Guest memory and the cores are not board fields, so the run that owns
//! them saves them beside this (RA8EMU-660). Each section loads all or
//! nothing on its own, but a failure in a later section leaves the earlier
//! ones loaded: load into a freshly built board and drop it on error, the
//! same rule as cpu.zig. A file from another part is refused before any
//! section is touched.
const std = @import("std");
const file = @import("file.zig");
const fields = @import("fields.zig");
const time = @import("time.zig");
const Part = @import("../chip/core/part.zig").Part;

pub const Error = file.Error || fields.Error || error{ Missing, WrongPart };

/// The board-shaped sections after time, in kind order. Appending is a
/// format change.
const sections = .{
    @import("timers.zig"),      @import("serial.zig"),  @import("sd.zig"),
    @import("wire.zig"),        @import("raster.zig"),  @import("display.zig"),
    @import("panel.zig"),       @import("clocks.zig"),  @import("security.zig"),
    @import("controllers.zig"), @import("storage.zig"), @import("signals.zig"),
    @import("datapath.zig"),    @import("media.zig"),   @import("wired.zig"),
    @import("channels.zig"),    @import("usb.zig"),     @import("rswitch.zig"),
    @import("npu.zig"),         @import("c6.zig"),
};

pub fn save(board: anytype, writer: anytype) !void {
    try file.writeSectionHeader(writer, .part, 1);
    try fields.write(writer, @as(u8, @backingInt(board.part)));
    try time.save(&board.time, writer);
    inline for (sections) |section| try section.save(board, writer);
}

/// Restores every board section of a whole snapshot file. See the file
/// comment for what an error leaves behind.
pub fn load(board: anytype, bytes: []const u8) LoadError()!void {
    try partOf(board.part, bytes);
    try time.load(&board.time, bytes);
    inline for (sections) |section| try section.load(board, bytes);
}

/// Every error a load can end in: this file's and each section's.
fn LoadError() type {
    comptime var all = Error || time.Error;
    inline for (sections) |section| all = all || section.Error;
    return all;
}

/// Refuses a file without a part section or from a different part.
pub fn partOf(expected: Part, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .part) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    const tag = try fields.read(u8, &cursor);
    if (!cursor.done()) return Error.BadValue;
    if (tag != @backingInt(expected)) return Error.WrongPart;
}
