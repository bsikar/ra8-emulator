//! The R-Switch mode machine: the steps it takes and the ones it refuses.
const std = @import("std");
const ra8 = @import("ra8");
const eth_mode = ra8.periph.eth_mode;

test "the machine starts in reset" {
    const machine = eth_mode.Machine{};
    try std.testing.expectEqual(eth_mode.Mode.reset, machine.mode);
    try std.testing.expect(machine.quiet());
}

test "the bring-up ladder is taken one rung at a time" {
    var machine = eth_mode.Machine{};
    for ([_]u32{ 1, 2, 3 }) |code| machine.command(code);
    try std.testing.expectEqual(eth_mode.Mode.operation, machine.mode);
    try std.testing.expectEqual(@as(u32, 3), machine.changes);
    try std.testing.expectEqual(@as(u32, 0), machine.refused);
}

test "a jump from reset to operation is refused, and the machine stays put" {
    var machine = eth_mode.Machine{};
    machine.command(3);
    try std.testing.expectEqual(eth_mode.Mode.reset, machine.mode);
    try std.testing.expectEqual(@as(u32, 1), machine.refused);
    try std.testing.expectEqual(eth_mode.Mode.operation, machine.last_refused.?);
}

test "reset is reachable from anywhere" {
    var machine = eth_mode.Machine{};
    for ([_]u32{ 1, 2, 3, 0 }) |code| machine.command(code);
    try std.testing.expectEqual(eth_mode.Mode.reset, machine.mode);
    try std.testing.expectEqual(@as(u32, 0), machine.refused);
}

test "commanding the mode it is already in changes nothing and is not refused" {
    var machine = eth_mode.Machine{};
    machine.command(1);
    machine.command(1);
    try std.testing.expectEqual(@as(u32, 1), machine.changes);
    try std.testing.expectEqual(@as(u32, 2), machine.commands);
    try std.testing.expectEqual(@as(u32, 0), machine.refused);
}

test "operation steps back to config but not to disable" {
    var machine = eth_mode.Machine{};
    for ([_]u32{ 1, 2, 3 }) |code| machine.command(code);
    machine.command(1);
    try std.testing.expectEqual(eth_mode.Mode.operation, machine.mode);
    try std.testing.expectEqual(@as(u32, 1), machine.refused);
    machine.command(2);
    try std.testing.expectEqual(eth_mode.Mode.config, machine.mode);
}

test "the status register reports where the machine is, not what it was asked" {
    var machine = eth_mode.Machine{};
    machine.command(3);
    try std.testing.expectEqual(@as(u32, 0), machine.status());
    machine.command(1);
    try std.testing.expectEqual(@as(u32, 1), machine.status());
}

test "every step off the ladder is one the table refuses" {
    try std.testing.expect(eth_mode.reachable(.disable, .config));
    try std.testing.expect(!eth_mode.reachable(.disable, .operation));
    try std.testing.expect(!eth_mode.reachable(.reset, .config));
    try std.testing.expect(eth_mode.reachable(.operation, .reset));
}

test "the mode command only reads its own two bits" {
    var machine = eth_mode.Machine{};
    machine.command(0xFFFF_FFFD);
    try std.testing.expectEqual(eth_mode.Mode.disable, machine.mode);
}

test "operational is the one mode the rings live in" {
    var machine = eth_mode.Machine{};
    for ([_]u32{ 1, 2 }) |code| machine.command(code);
    try std.testing.expect(!machine.operational());
    machine.command(3);
    try std.testing.expect(machine.operational());
}
