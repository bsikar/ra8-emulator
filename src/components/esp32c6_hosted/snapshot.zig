//! The board's ESP32-C6 companion in a snapshot (RA8EMU-687).
//!
//! Live host sockets are runtime resources: successful load closes and clears
//! them, while a failed load leaves the target bridge untouched.
const std = @import("std");
const file = @import("ra8_snapshot").file;
const fields = @import("ra8_snapshot").fields;

pub const Error = file.Error || fields.Error || error{Missing};

const wiring = .{ "pins", "wire.bridge" };

pub fn save(board: anytype, writer: anytype) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try fields.writeExcept(&counter.writer, board.c6, wiring);
    try file.writeSectionHeader(writer, .c6, counter.fullCount());
    try fields.writeExcept(writer, board.c6, wiring);
}

/// All or nothing: failed parsing leaves emulated state and live sockets alone.
pub fn load(board: anytype, bytes: []const u8) Error!void {
    const section = try file.Reader.find(bytes, .c6) orelse return Error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var copy: @TypeOf(board.c6) = .{ .pins = board.c6.pins };
    try fields.readOver(&cursor, &copy, wiring);
    if (!cursor.done() or !fits(copy.wire)) return Error.BadValue;
    board.c6.wire.bridge.closeFlows();
    copy.wire.bridge = board.c6.wire.bridge;
    board.c6 = copy;
}

fn fits(wire: anytype) bool {
    const queue = wire.queue;
    return wire.offset <= wire.rx.len and wire.caps_len <= wire.caps.len and
        queue.head < queue.slots.len and queue.len <= queue.slots.len;
}

/// Guest payload only. The caller supplies detached storage with no flows.
pub fn writePayload(writer: *std.Io.Writer, part: anytype) !void {
    if (!fits(part.wire) or part.wire.offset >= part.wire.rx.len) return error.BadValue;
    var copy = part.*;
    @memset(copy.wire.rx[copy.wire.offset..], 0);
    if (copy.wire.offset == 0) @memset(&copy.wire.tx, 0);
    for (&copy.wire.queue.slots, 0..) |*slot, index| {
        const distance = (index + copy.wire.queue.slots.len - copy.wire.queue.head) % copy.wire.queue.slots.len;
        if (distance >= copy.wire.queue.len) @memset(slot, 0);
    }
    try fields.writeExcept(writer, copy, wiring);
}

pub fn readPayload(part: anytype, cursor: *fields.Cursor) fields.Error!void {
    try fields.readOver(cursor, part, wiring);
    if (!cursor.done() or !fits(part.wire) or part.wire.offset >= part.wire.rx.len) return error.BadValue;
}

/// Rebuild the private sideband callback without changing saved pin levels.
/// This runs at commit. The connect operation touches a local scratch GPIO.
pub fn rebindPins(part: anytype, pins: anytype, observe: bool) void {
    var scratch: @TypeOf(pins.*) = .{};
    part.connect(&scratch);
    part.pins = pins;
    if (observe) pins.observer = scratch.observer;
}

/// Recognize the model's sideband observer while leaving host taps alone.
pub fn observerMatches(part: anytype, pins: anytype) bool {
    const observer = pins.observer orelse return false;
    if (observer.context != @as(*anyopaque, part)) return false;
    var probe: @TypeOf(part.*) = .{};
    var scratch: @TypeOf(pins.*) = .{};
    probe.connect(&scratch);
    return observer.changedFn == scratch.observer.?.changedFn;
}
