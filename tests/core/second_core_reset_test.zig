//! Tests for src/core/second_core.zig: a SYSRESETREQ from CPU1 (RA8EMU-59).
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.core.second_core;
const memmap = ra8.core.memmap;
const Engine = ra8.core.engine.Engine;
const Board = ra8.board.Board;
const scb = ra8.periph.scb;

/// CPU1 beside CPU0 on shared RAM, built into storage the caller holds.
fn pair(cpu1: *mod.Second) !Engine {
    var cpu0 = try Engine.open();
    errdefer cpu0.close();
    try cpu0.mapBoardRam();
    cpu1.* = .{ .core = try Engine.open() };
    errdefer cpu1.close();
    try cpu1.core.shareBoardRamWith(&cpu0);
    return cpu0;
}

test "a reset CPU1 asks for latches SWRF and reboots the part, as CPU0's does" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var pending: ra8.core.reboot.Reboot = .{};
    board.reboot = &pending;
    cpu1.control = scb.Scb.init();
    try cpu1.control.prime(cpu1.core);
    cpu1.takeResetRequest();
    try std.testing.expect(!pending.requested);

    cpu1.board = &board;
    const keyed: u32 = scb.key.write << scb.key.shift;
    try cpu1.core.writeWord(memmap.scb.aircr, keyed | scb.field.sysresetreq);
    cpu1.takeResetRequest();
    try std.testing.expect(pending.requested);
    try std.testing.expect(board.causes.rstsr1 & ra8.periph.reset.cause.swrf != 0);
    try std.testing.expectEqual(@as(u32, 1), board.causes.requests);
}

test "a reset the board performs holds CPU1, which then retires nothing" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var pending: ra8.core.reboot.Reboot = .{};
    board.reboot = &pending;
    cpu1.board = &board;
    try std.testing.expect(!cpu1.heldInReset());

    pending.performed = 1;
    try std.testing.expect(cpu1.heldInReset());
    cpu1.step(100);
    try std.testing.expectEqual(@as(usize, 0), cpu1.ran);
    try std.testing.expectEqual(@as(u32, 0), cpu1.turns);
    try std.testing.expect(cpu1.heldInReset());
}

test "a core with no board is never held" {
    var cpu1: mod.Second = undefined;
    var cpu0 = try pair(&cpu1);
    defer cpu0.close();
    defer cpu1.close();
    try std.testing.expect(!cpu1.heldInReset());
}
