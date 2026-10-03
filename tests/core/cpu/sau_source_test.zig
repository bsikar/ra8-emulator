//! Tests for src/core/cpu/sau_source.zig with and without the board's
//! IDAU map (RA8EMU-277).
const std = @import("std");
const ra8 = @import("ra8");
const sau = ra8.periph.sau;
const cpu_mod = ra8.core.cpu.cpu;
const SauSource = cpu_mod.sau_source.SauSource;
const State = cpu_mod.attribution.State;
const SramUnit = ra8.periph.cpscu.sram.Unit;

const enable: u32 = 1 << 0;
const tt_s: u32 = 1 << 22;

/// Region 0 over `base`..`limit`, Non-secure.
fn nonSecure(unit: *sau.Sau, base: u32, limit: u32) void {
    unit.table[0] = sau.Region.fromPair(base, (limit & 0xFFFF_FFE0) | 1);
}

test "with no map the SAU alone decides, as before" {
    var unit = sau.Sau{ .ctrl = enable };
    nonSecure(&unit, 0x0200_0000, 0x0200_FFFF);
    var source = SauSource{ .unit = &unit };
    try std.testing.expectEqual(State.non_secure, source.source().of(0x0200_0100));
}

test "the map keeps bit-28-clear code out of Non-secure" {
    var unit = sau.Sau{ .ctrl = enable };
    nonSecure(&unit, 0x0200_0000, 0x0200_FFFF);
    const map = sau.idau.Map{};
    var source = SauSource{ .unit = &unit, .idau = &map };
    try std.testing.expectEqual(State.callable, source.source().of(0x0200_0100));
}

test "the Non-secure code alias stays Non-secure under the map" {
    var unit = sau.Sau{ .ctrl = enable };
    nonSecure(&unit, 0x1200_0000, 0x1200_FFFF);
    const map = sau.idau.Map{};
    var source = SauSource{ .unit = &unit, .idau = &map };
    try std.testing.expectEqual(State.non_secure, source.source().of(0x1200_0100));
}

test "TT on SRAM below a bank's boundary reports Secure" {
    var unit = sau.Sau{ .ctrl = enable };
    nonSecure(&unit, 0x3200_0000, 0x3200_FFFF);
    const sram = SramUnit{ .sabar = .{ 0x0008_0000, 0x0010_0000, 0x0018_0000, 0x001A_0000 } };
    const map = sau.idau.Map{ .sram = &sram };
    var mapped = SauSource{ .unit = &unit, .idau = &map };
    var bare = SauSource{ .unit = &unit };
    const word = mapped.source().respondFn.?(@ptrCast(&mapped), 0x3200_0100, true);
    const before = bare.source().respondFn.?(@ptrCast(&bare), 0x3200_0100, true);
    try std.testing.expect(word & tt_s != 0);
    try std.testing.expect(before & tt_s == 0);
}
