//! Snapshot serialization for RA4T1 on-chip peripherals.
const std = @import("std");

const fields = @import("ra8_snapshot").fields;
const file = @import("ra8_snapshot").file;
const ra4t1 = @import("ra4t1.zig");

pub const Error = file.Error || fields.Error || error{Missing};

const guard_wiring = .{"protection"};
const sci_wiring = .{ "tx_sink", "irq_sink" };

pub fn save(board: anytype, writer: anytype) !void {
    if (board.desc().memory.resolvedPeripherals() != .ra4t1) return;
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try body(&counter.writer, &board.ra4t1);
    try file.writeSectionHeader(writer, .ra4t1, counter.fullCount());
    try body(writer, &board.ra4t1);
}

fn body(writer: anytype, state: *const ra4t1.State) !void {
    try fields.write(writer, state.sysc);
    try fields.writeExcept(writer, state.fcache, guard_wiring);
    try fields.writeExcept(writer, state.pscu, guard_wiring);
    try fields.write(writer, state.mstp);
    try fields.writeExcept(writer, state.port, guard_wiring);
    try fields.writeExcept(writer, state.sci, sci_wiring);
    try fields.write(writer, state.icu);
    try fields.write(writer, state.timers);
    try fields.write(writer, state.flash_ctrl);
}

pub fn load(board: anytype, bytes: []const u8) Error!void {
    if (board.desc().memory.resolvedPeripherals() != .ra4t1) return;
    const section = try file.Reader.find(bytes, .ra4t1) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy = board.ra4t1;
    try fields.readOver(&cursor, &copy.sysc, .{});
    try fields.readOver(&cursor, &copy.fcache, guard_wiring);
    try fields.readOver(&cursor, &copy.pscu, guard_wiring);
    try fields.readOver(&cursor, &copy.mstp, .{});
    try fields.readOver(&cursor, &copy.port, guard_wiring);
    try fields.readOver(&cursor, &copy.sci, sci_wiring);
    try fields.readOver(&cursor, &copy.icu, .{});
    try fields.readOver(&cursor, &copy.timers, .{});
    try fields.readOver(&cursor, &copy.flash_ctrl, .{});
    if (!cursor.done()) return Error.BadValue;
    board.ra4t1 = copy;
}
