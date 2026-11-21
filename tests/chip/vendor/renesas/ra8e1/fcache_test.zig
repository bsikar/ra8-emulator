//! Covers src/chip/vendor/renesas/ra8e1/fcache.zig: FCACHEE, FCACHEIV, FLWT, and FSAR.
const ra8 = @import("ra8");
const std = @import("std");

const fcache = ra8.chip.vendor.renesas.ra8e1.fcache;
const prcr = ra8.chip.periph.prcr;
const registry = ra8.chip.periph.registry;

test "reset defaults match R01UH1129EJ0110 section 49.4" {
    var prot = prcr.Prcr.init();
    var unit = fcache.Fcache.init(&prot);
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.read(fcache.win_base + fcache.off.fcachee, 2));
    try std.testing.expectEqual(@as(u32, 0), unit.read(fcache.win_base + fcache.off.fcacheiv, 2));
    try std.testing.expectEqual(@as(u32, 0), unit.read(fcache.win_base + fcache.off.flwt, 1));
    try std.testing.expectEqual(@as(u32, 0), unit.read(fcache.win_base + fcache.off.fsar, 2));
}

test "FLWT retains wait cycles bits 2:0 and FCACHEE retains enable bit 0" {
    var unit = fcache.Fcache.init(null);
    unit.write(fcache.win_base + fcache.off.flwt, 1, 0xFC);
    try std.testing.expectEqual(@as(u32, 0x04), unit.read(fcache.win_base + fcache.off.flwt, 1));
    unit.write(fcache.win_base + fcache.off.flwt, 1, 0x00);
    try std.testing.expectEqual(@as(u32, 0x00), unit.read(fcache.win_base + fcache.off.flwt, 1));

    unit.write(fcache.win_base + fcache.off.fcachee, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 1), unit.read(fcache.win_base + fcache.off.fcachee, 2));
    unit.write(fcache.win_base + fcache.off.fcacheiv, 2, 0x0001);
    try std.testing.expectEqual(@as(u32, 0), unit.read(fcache.win_base + fcache.off.fcacheiv, 2));
    try std.testing.expectEqual(@as(u32, 1), unit.invalidations);
    try std.testing.expect(!unit.quiet());
}

test "FSAR requires PRCR.PRC4 unlock and masks valid bits" {
    var prot = prcr.Prcr.init();
    var unit = fcache.Fcache.init(&prot);
    unit.write(fcache.win_base + fcache.off.fsar, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(fcache.win_base + fcache.off.fsar, 2));
    try std.testing.expectEqual(@as(u32, 1), unit.dropped_locked);

    prot.write(prcr.win_base, 2, prcr.unlockWord(prcr.group.sar));
    unit.write(fcache.win_base + fcache.off.fsar, 2, 0xFFFF);
    try std.testing.expectEqual(@as(u32, fcache.mask.fsar), unit.read(fcache.win_base + fcache.off.fsar, 2));
}

test "FCACHE answers via peripheral bus for secure and NS addresses" {
    var bus = registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = fcache.Fcache.init(null);
    try bus.add(unit.block());
    bus.write(0x5001_C11C, 1, 0x03);
    try std.testing.expectEqual(@as(u32, 0x03), bus.read(0x4001_C11C, 1));
    try std.testing.expectEqual(@as(u32, 0x03), bus.read(0x5001_C11C, 1));
}
