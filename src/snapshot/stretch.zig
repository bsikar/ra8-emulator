//! What a saved run owed its clocks (RA8EMU-700): the instructions its last
//! stretch retired before the budget ran out, not yet charged. A load starts
//! the first stretch that far in (boot.Owed), so the restored run's
//! boundaries land where an uninterrupted run's do.
//!
//! A file saved before this section existed loads as owing nothing, the
//! behaviour it was saved under.
const std = @import("std");
const file = @import("file.zig");

pub const Error = file.Error || error{BadValue};

pub fn save(owed: u32, writer: anytype) !void {
    try file.writeSectionHeader(writer, .stretch, @sizeOf(u32));
    try writer.writeInt(u32, owed, .little);
}

pub fn load(bytes: []const u8) Error!u32 {
    const section = try file.Reader.find(bytes, .stretch) orelse return 0;
    if (section.payload.len != @sizeOf(u32)) return Error.BadValue;
    return std.mem.readInt(u32, section.payload[0..4], .little);
}
