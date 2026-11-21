//! Unit tests for RA4T1 `FCACHE` (`0x4001_C100`).
const ra8 = @import("ra8");
const std = @import("std");

const fcache = ra8.chip.vendor.renesas.ra4t1.fcache;
const sysc = ra8.chip.vendor.renesas.ra4t1.sysc;

test "FCACHE FLWT, invalidate, and FSAR PRC4 protection" {
    var guard = sysc.Sysc.init();
    var unit = fcache.Fcache.init(&guard);
    try std.testing.expectEqual(@as(u32, 0), unit.read(fcache.win_base + fcache.ofs.flwt, 1));
    try std.testing.expectEqual(@as(u32, 0xFFFF), unit.read(fcache.win_base + fcache.ofs.fsar, 2));

    unit.write(fcache.win_base + fcache.ofs.flwt, 1, 1);
    try std.testing.expectEqual(@as(u32, 1), unit.read(fcache.win_base + fcache.ofs.flwt, 1));

    unit.write(fcache.win_base + fcache.ofs.fcacheiv, 2, 1);
    try std.testing.expectEqual(@as(u32, 1), unit.invalidations);
    try std.testing.expectEqual(@as(u32, 0), unit.read(fcache.win_base + fcache.ofs.fcacheiv, 2));

    unit.write(fcache.win_base + fcache.ofs.fsar, 2, 0x0000);
    try std.testing.expectEqual(@as(u16, 0xFFFF), unit.fsar);
    guard.write(sysc.win_base + sysc.ofs.prcr, 2, 0xA510);
    unit.write(fcache.win_base + fcache.ofs.fsar, 2, 0x0000);
    try std.testing.expectEqual(@as(u16, 0xFEFE), unit.fsar);
}
