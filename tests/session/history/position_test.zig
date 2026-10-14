//! Covers src/session/history/position.zig: the scheduler position on the
//! wire, the places a round could and could not have had, and the line
//! comparison that refuses to rank two branches.
const std = @import("std");
const ra8 = @import("ra8");
const history_position = ra8.session.history_position;
const scheduler = ra8.chip.core.scheduler;

fn roundTrip(position: scheduler.Position) !history_position.Position {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try history_position.encode(&buf.writer, position);
    var at: usize = 0;
    return history_position.decode(buf.written(), &at);
}

test "a position round trips through its little-endian bytes" {
    const original: scheduler.Position = .{ .branch = 3, .r = 0x1_0000_0002, .phase = .cpu1, .o = 7, .gap = .polled };
    try std.testing.expectEqual(original, try roundTrip(original));
}

test "the places a cut round could not have had are refused" {
    const facts: history_position.RoundFacts = .{ .cpu0 = 5, .cpu1 = 0, .cut = true };
    try history_position.validate(.{ .r = 1, .phase = .cpu0, .o = 4, .gap = .polled }, facts);
    try history_position.validate(.{ .r = 1, .phase = .cpu0, .o = 0, .gap = .retired }, facts);
    try std.testing.expectError(error.Impossible, history_position.validate(.{ .r = 1, .phase = .cpu1, .o = 0, .gap = .retired }, facts));
}

test "offsets stop at the slots the round ran" {
    const facts: history_position.RoundFacts = .{ .cpu0 = 3, .cpu1 = 2 };
    try history_position.validate(.{ .r = 2, .phase = .cpu0, .o = 2, .gap = .retired }, facts);
    try history_position.validate(.{ .r = 2, .phase = .cpu1, .o = 1, .gap = .polled }, facts);
    try std.testing.expectError(error.Impossible, history_position.validate(.{ .r = 2, .phase = .cpu0, .o = 3, .gap = .retired }, facts));
    try std.testing.expectError(error.Impossible, history_position.validate(.{ .r = 2, .phase = .cpu1, .o = 2, .gap = .polled }, facts));
    // An empty CPU1 phase holds only its own start.
    const held: history_position.RoundFacts = .{ .cpu0 = 4, .cpu1 = 0 };
    try history_position.validate(.{ .r = 2, .phase = .cpu1, .o = 0, .gap = .retired }, held);
    try std.testing.expectError(error.Impossible, history_position.validate(.{ .r = 2, .phase = .cpu1, .o = 0, .gap = .polled }, held));
}

test "the board phase is atomic, at its retire gap, and never past its tick" {
    const facts: history_position.RoundFacts = .{ .cpu0 = 1, .cpu1 = 1 };
    try history_position.validate(.{ .r = 0, .phase = .board, .o = 0, .gap = .retired }, facts);
    try history_position.validate(.{ .r = 0, .phase = .board, .o = 1, .gap = .retired }, facts);
    try std.testing.expectError(error.Impossible, history_position.validate(.{ .r = 0, .phase = .board, .o = 2, .gap = .retired }, facts));
    try std.testing.expectError(error.Impossible, history_position.validate(.{ .r = 0, .phase = .board, .o = 1, .gap = .polled }, facts));
}

test "positions on different lines do not order, on one line they do" {
    const a: scheduler.Position = .{ .branch = 1, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired };
    const b: scheduler.Position = .{ .branch = 2, .r = 0, .phase = .board, .o = 0, .gap = .retired };
    try std.testing.expectError(error.OtherLine, history_position.compare(a, b));
    const later = a;
    try std.testing.expectEqual(std.math.Order.gt, try history_position.compare(.{ .r = 5, .branch = 1 }, later));
}

test "a phase or gap outside its type is refused, and a short payload is torn" {
    var bytes: [18]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], 0, .little);
    std.mem.writeInt(u64, bytes[4..12], 1, .little);
    bytes[12] = 3; // phase 3 does not exist
    std.mem.writeInt(u32, bytes[13..17], 0, .little);
    bytes[17] = 0;
    var at: usize = 0;
    try std.testing.expectError(error.BadValue, history_position.decode(&bytes, &at));
    at = 0;
    try std.testing.expectError(error.Truncated, history_position.decode(bytes[0..5], &at));
}
