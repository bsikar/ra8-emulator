//! The board's Ethernet switch in a snapshot (RA8EMU-683): both ports, their
//! agents, the forwarding engine, the setup words, COMA, the gateway and
//! pool, and the descriptor queues with their DMA state and peer link, as
//! one `rswitch` section.
//!
//! Not saved, because it is wiring that `attach` lays into the board itself:
//! each port's ESWM power domain, the gateway's view of the forwarding
//! words, the queues' view of the gateway mode and the DMA's guest memory.
//! A load keeps the target's.
const std = @import("std");
const file = @import("file.zig");
const fields = @import("fields.zig");

pub const Error = file.Error || fields.Error || error{Missing};

const skip: []const []const u8 = &.{ "ports.domain", "gateway.fwpc", "queues.mode", "queues.rings.memory" };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try fields.writeExcept(&counter.writer, board.rswitch, skip);
    try file.writeSectionHeader(writer, .rswitch, counter.fullCount());
    try fields.writeExcept(writer, board.rswitch, skip);
}

/// All or nothing: the section is read over a copy, and the board changes
/// only once the whole section read cleanly.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .rswitch) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy = board.rswitch;
    try fields.readOver(&cursor, &copy, skip);
    if (!cursor.done()) return Error.BadValue;
    board.rswitch = copy;
}
