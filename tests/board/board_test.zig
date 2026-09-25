//! Covers src/board/board.zig: the board wires every block onto one bus and
//! carries the chunk boundary, so this checks the wiring rather than the
//! models, which have their own test files.
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.Board;
const reset = ra8.periph.reset;
const wdt = ra8.periph.wdt;

/// A board with a bus but no CPU behind it. attach() needs an engine, so the
/// tests that only ask about the peripheral state build the board directly.
fn board() Board {
    return Board.init(std.testing.allocator);
}

test "a fresh board reads back a power-on reset" {
    var unit = board();
    defer unit.deinit();
    try std.testing.expect(unit.causes.rstsr0 & reset.cause.porf != 0);
    try std.testing.expect(unit.causes.quiet());
}

test "a watchdog that asked for a reset hands it to the reset block" {
    var unit = board();
    defer unit.deinit();
    unit.watchdog.reset_requested = true;
    unit.takeResetRequests();
    try std.testing.expect(unit.causes.latched(reset.cause.wdtrf));
    try std.testing.expect(unit.causes.rstsr0 & reset.cause.porf == 0);
    try std.testing.expectEqual(@as(u32, 1), unit.causes.requests);
    // Taken once: the request is cleared, so the next boundary does not
    // latch a second reboot for the same underflow.
    try std.testing.expect(!unit.watchdog.reset_requested);
    unit.takeResetRequests();
    try std.testing.expectEqual(@as(u32, 1), unit.causes.requests);
}

test "a watchdog that never fired leaves the boot cause alone" {
    var unit = board();
    defer unit.deinit();
    unit.takeResetRequests();
    try std.testing.expect(unit.causes.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.causes.requests);
}

test "an underflow with RSTIRQS set reaches the reset block through the board" {
    var unit = board();
    defer unit.deinit();
    // Arm the counter the way the refresh sequence does, ask for a reset on
    // underflow, then run it dry a boundary at a time.
    unit.watchdog.wdtrcr = wdt.reset_control.rstirqs;
    unit.watchdog.armed = true;
    unit.watchdog.counter = 1;
    unit.watchdog.tick();
    unit.takeResetRequests();
    try std.testing.expect(unit.causes.quiet());
    unit.watchdog.tick();
    unit.takeResetRequests();
    try std.testing.expectEqual(@as(u32, 1), unit.watchdog.underflows);
    try std.testing.expect(unit.causes.latched(reset.cause.wdtrf));
}
