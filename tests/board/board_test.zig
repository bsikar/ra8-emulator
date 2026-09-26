//! Covers src/board/board.zig: the board wires every block onto one bus and
//! carries the chunk boundary, so this checks the wiring rather than the
//! models, which have their own test files.
const std = @import("std");
const ra8 = @import("ra8");

const Board = ra8.board.Board;
const memmap = ra8.core.memmap;
const scb = ra8.periph.scb;
const icu = ra8.periph.icu;
const reboot = ra8.core.reboot;
const reset = ra8.periph.reset;
const wdt = ra8.periph.wdt;

/// A board with a bus but no CPU behind it. attach() needs an engine, so the
/// tests that only ask about the peripheral state build the board directly.
fn board() Board {
    return Board.init(std.testing.allocator);
}

/// The one PPB word the boundary reads, standing in for the engine. AIRCR is
/// the only address takeResetRequests touches on the core.
const Ppb = struct {
    word: u32 = scb.key.status,

    pub fn readWord(self: *Ppb, address: u32) !u32 {
        try std.testing.expectEqual(memmap.scb.aircr, address);
        return self.word;
    }

    pub fn writeWord(self: *Ppb, address: u32, value: u32) !void {
        try std.testing.expectEqual(memmap.scb.aircr, address);
        self.word = value;
    }

    /// The store `ra8_reset_software_reset` makes.
    fn requestReset(self: *Ppb) void {
        self.word = (scb.key.write << scb.key.shift) | scb.field.sysresetreq;
    }
};

test "a fresh board reads back a power-on reset" {
    var unit = board();
    defer unit.deinit();
    try std.testing.expect(unit.causes.rstsr0 & reset.cause.porf != 0);
    try std.testing.expect(unit.causes.quiet());
}

test "a watchdog that asked for a reset hands it to the reset block" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    unit.watchdog.reset_requested = true;
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.latched(reset.cause.wdtrf));
    try std.testing.expect(unit.causes.rstsr0 & reset.cause.porf == 0);
    try std.testing.expectEqual(@as(u32, 1), unit.causes.requests);
    // Taken once: the request is cleared, so the next boundary does not
    // latch a second reboot for the same underflow.
    try std.testing.expect(!unit.watchdog.reset_requested);
    try unit.takeResetRequests(&ppb);
    try std.testing.expectEqual(@as(u32, 1), unit.causes.requests);
}

test "a watchdog that never fired leaves the boot cause alone" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.causes.requests);
}

test "an underflow with RSTIRQS set reaches the reset block through the board" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    // Arm the counter the way the refresh sequence does, ask for a reset on
    // underflow, then run it dry a boundary at a time.
    unit.watchdog.wdtrcr = wdt.reset_control.rstirqs;
    unit.watchdog.armed = true;
    unit.watchdog.counter = 1;
    unit.watchdog.tick();
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.quiet());
    unit.watchdog.tick();
    try unit.takeResetRequests(&ppb);
    try std.testing.expectEqual(@as(u32, 1), unit.watchdog.underflows);
    try std.testing.expect(unit.causes.latched(reset.cause.wdtrf));
}

test "a keyed SYSRESETREQ latches a software cause and asks for the reboot" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    var pending = reboot.Reboot{ .vector_base = 0x0200_0000 };
    unit.reboot = &pending;
    ppb.requestReset();
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(unit.causes.latched(reset.cause.swrf));
    try std.testing.expect(pending.requested);
    try std.testing.expectEqual(@as(u32, 1), unit.control.requests);
}

test "a keyless SYSRESETREQ reboots nothing" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    var pending = reboot.Reboot{ .vector_base = 0x0200_0000 };
    unit.reboot = &pending;
    ppb.word = scb.field.sysresetreq;
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(!unit.causes.latched(reset.cause.swrf));
    try std.testing.expect(!pending.requested);
    try std.testing.expectEqual(@as(u32, 1), unit.control.rejected);
}

test "a software reset takes the interrupt latches down" {
    var unit = board();
    defer unit.deinit();
    var ppb = Ppb{};
    unit.events.links[3] = icu.field.ir | 7;
    try std.testing.expect(unit.events.latched(3));
    ppb.requestReset();
    try unit.takeResetRequests(&ppb);
    try std.testing.expect(!unit.events.latched(3));
    // The link itself survives: this tree keeps peripheral state across a
    // reboot, and only the flag would have re-pended into a bare firmware.
    try std.testing.expectEqual(@as(u32, 7), unit.events.links[3] & icu.field.iels);
}
