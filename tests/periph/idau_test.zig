//! Tests for src/periph/idau.zig.

const std = @import("std");
const ra8 = @import("ra8");
const sau = ra8.periph.sau;
const idau = sau.idau;
const State = sau.attribution.State;
const SramUnit = ra8.periph.cpscu.sram.Unit;

const enable: u32 = 1 << 0;
const allns: u32 = 1 << 1;

fn program(unit: *sau.Sau, index: usize, base: u32, limit: u32, nsc: bool) void {
    const rlar = (limit & 0xFFFF_FFE0) | (if (nsc) @as(u32, 2) else 0) | 1;
    unit.table[index] = sau.Region.fromPair(base, rlar);
}

/// The ereader boot's boundary set: SRAM2 Non-secure, the rest Secure.
fn ereaderSram() SramUnit {
    return .{ .sabar = .{ 0x0008_0000, 0x0010_0000, 0x0010_0000, 0x001A_0000 } };
}

test "bit 28 clear is Secure but may be made callable" {
    const map = idau.Map{};
    for ([_]u32{ 0x0200_0000, 0x2200_0000, 0x4000_8000 }) |address| {
        try std.testing.expectEqual(State.callable, map.answer(address).state);
    }
}

test "bit 28 set is Non-secure with no SRAM boundaries" {
    const map = idau.Map{};
    for ([_]u32{ 0x1200_0000, 0x3200_0000, 0x5000_0000 }) |address| {
        try std.testing.expectEqual(State.non_secure, map.answer(address).state);
    }
}

test "the SRAM alias follows each bank's boundary" {
    const sram = ereaderSram();
    const map = idau.Map{ .sram = &sram };
    try std.testing.expectEqual(State.secure, map.answer(0x3200_0000).state);
    try std.testing.expectEqual(State.secure, map.answer(0x3208_0000).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x3210_0000).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x3217_FFFC).state);
    try std.testing.expectEqual(State.secure, map.answer(0x3218_0000).state);
}

test "a boundary inside a bank splits it" {
    var sram = SramUnit{};
    sram.sabar[1] = 0x000C_0000;
    const map = idau.Map{ .sram = &sram };
    try std.testing.expectEqual(State.secure, map.answer(0x320B_FFFC).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x320C_0000).state);
}

test "SRAM past the last bank and other bit-28 space stay Non-secure" {
    const sram = ereaderSram();
    const map = idau.Map{ .sram = &sram };
    try std.testing.expectEqual(State.non_secure, map.answer(0x321A_0000).state);
    try std.testing.expectEqual(State.non_secure, map.answer(0x1200_0000).state);
}

test "the SAU cannot make bit-28-clear code Non-secure, only callable" {
    var unit = sau.Sau{ .ctrl = enable };
    program(&unit, 0, 0x0200_0000, 0x0200_FFFF, false);
    program(&unit, 1, 0x0201_0000, 0x0201_0FFF, true);
    const map = idau.Map{};
    try std.testing.expectEqual(State.callable, map.attribute(&unit, 0x0200_0100).state);
    try std.testing.expectEqual(State.callable, map.attribute(&unit, 0x0201_0000).state);
    try std.testing.expectEqual(State.secure, map.attribute(&unit, 0x0300_0000).state);
}

test "attribution is never looser than the IDAU" {
    const sram = ereaderSram();
    const map = idau.Map{ .sram = &sram };
    const units = [_]sau.Sau{ .{}, .{ .ctrl = allns } };
    const addresses = [_]u32{ 0x0200_0000, 0x1200_0000, 0x2200_0000, 0x3200_0000, 0x3210_0000, 0x3218_0000, 0x5000_0000 };
    for (units) |unit| for (addresses) |address| {
        const got = map.attribute(&unit, address);
        if (got.exempt) continue;
        const floor = map.answer(address).state;
        try std.testing.expect(@intFromEnum(got.state) >= @intFromEnum(floor));
    };
}

test "the debug and system ranges stay exempt" {
    const map = idau.Map{};
    const unit = sau.Sau{ .ctrl = allns };
    try std.testing.expect(map.attribute(&unit, 0xE000_ED00).exempt);
}

test "no answer names an IDAU region" {
    const map = idau.Map{};
    try std.testing.expectEqual(@as(?u8, null), map.answer(0x2200_0000).region);
}
