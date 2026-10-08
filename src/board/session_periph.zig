//! Session access to the board's peripheral layouts (RA8EMU-818): the
//! blocks on the bus, or the registers of one block, as text or JSON.
//! Both cores share the one peripheral bus, so either core gets the same
//! list.
const std = @import("std");
const Board = @import("board.zig").Board;
const periph = @import("../periph/registry.zig");
const layout = @import("periph_layout.zig");

/// The serve hook's list function, with a `*Board` as its context. The
/// board stays free of the interfaces: serve pairs the two.
pub fn listBoard(context: *anyopaque, core: usize, block: []const u8, json: bool, out: []u8) anyerror![]const u8 {
    const board: *Board = @ptrCast(@alignCast(context));
    return list(&board.bus, core, block, json, out);
}

/// The blocks on `bus` when `block` is empty, else that block's registers.
pub fn list(bus: *const periph.Bus, core: usize, block: []const u8, json: bool, out: []u8) ![]const u8 {
    if (core > 1) return error.NoSuchCore;
    if (block.len == 0) return if (json) blocksJson(bus, out) else layout.writeBlocks(bus, out);
    return if (json) registersJson(block, out) else layout.writeRegisters(block, out);
}

/// `[{"name":"RTC","base":N,"size":N},...]`.
pub fn blocksJson(bus: *const periph.Bus, out: []u8) error{NoSpaceLeft}![]const u8 {
    var writer: std.Io.Writer = .fixed(out);
    writeBlocksJson(&writer, bus) catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn writeBlocksJson(writer: *std.Io.Writer, bus: *const periph.Bus) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    for (layout.blocks(bus), 0..) |block, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try std.json.Stringify.encodeJsonString(block.name, .{}, writer);
        try writer.print(",\"base\":{d},\"size\":{d}}}", .{ block.base, block.size });
    }
    try writer.writeByte(']');
}

/// `{"block":"RTC","registers":[{"name":..,"offset":N,"width":N|null},...]}`.
pub fn registersJson(block: []const u8, out: []u8) error{ NoSpaceLeft, UnknownBlock }![]const u8 {
    const found = layout.registers(block) orelse return error.UnknownBlock;
    var writer: std.Io.Writer = .fixed(out);
    writeRegistersJson(&writer, block, found) catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn writeRegistersJson(writer: *std.Io.Writer, block: []const u8, found: []const layout.Register) std.Io.Writer.Error!void {
    try writer.writeAll("{\"block\":");
    try std.json.Stringify.encodeJsonString(block, .{}, writer);
    try writer.writeAll(",\"registers\":[");
    for (found, 0..) |register, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{{\"name\":\"{s}\",\"offset\":{d},\"width\":", .{ register.name, register.offset });
        if (register.width == 0) try writer.writeAll("null}") else try writer.print("{d}}}", .{register.width});
    }
    try writer.writeAll("]}");
}
