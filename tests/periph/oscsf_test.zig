//! Covers src/periph/oscsf.zig: the oscillation stabilisation flags and the
//! four stop bits they follow.
const std = @import("std");
const ra8 = @import("ra8");

const oscsf = ra8.periph.oscsf;

const base = oscsf.win_base;

fn unit() oscsf.Oscillators {
    return oscsf.Oscillators.init();
}

test "HOCO comes up running and the other three come up stopped" {
    var osc = unit();
    const flags = osc.flags();
    try std.testing.expect(flags & oscsf.flag.hocosf != 0);
    try std.testing.expect(flags & oscsf.flag.moscsf == 0);
    try std.testing.expect(flags & oscsf.flag.pll1sf == 0);
    try std.testing.expect(flags & oscsf.flag.pll2sf == 0);
}

test "clearing MOSTP raises MOSCSF and setting it drops the flag again" {
    var osc = unit();
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    try std.testing.expect(osc.running(oscsf.flag.moscsf));
    osc.write(base + oscsf.regs.mosccr, 1, 0x01);
    try std.testing.expect(!osc.running(oscsf.flag.moscsf));
}

test "stopping PLL1 drops PLL1SF, which is what the driver waits on" {
    var osc = unit();
    osc.write(base + oscsf.regs.pllcr, 1, 0x00);
    try std.testing.expect(osc.running(oscsf.flag.pll1sf));
    // internal_stop_pll1 writes PLLCR = stop outright, then waits for clear.
    osc.write(base + oscsf.regs.pllcr, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 0), osc.read(base + oscsf.regs.oscsf, 1) & oscsf.flag.pll1sf);
}

test "PLL2SF reads clear until PLL2 is actually started" {
    var osc = unit();
    // ra8_cgc_usb.c line 271 tests this once to decide whether to start PLL2.
    try std.testing.expect(!osc.running(oscsf.flag.pll2sf));
    osc.write(base + oscsf.regs.pll2cr, 1, 0x00);
    try std.testing.expect(osc.running(oscsf.flag.pll2sf));
}

test "OSCSF reads the same value twice, unlike the alternating fallback" {
    var osc = unit();
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    const first = osc.read(base + oscsf.regs.oscsf, 1);
    const second = osc.read(base + oscsf.regs.oscsf, 1);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u32, oscsf.flag.hocosf | oscsf.flag.moscsf), first);
}

test "OSCSF is read-only and a store to it is counted, not kept" {
    var osc = unit();
    const before = osc.read(base + oscsf.regs.oscsf, 1);
    osc.write(base + oscsf.regs.oscsf, 1, 0xFF);
    try std.testing.expectEqual(before, osc.read(base + oscsf.regs.oscsf, 1));
    try std.testing.expectEqual(@as(u32, 1), osc.readonly_writes);
}

test "a read-modify-write of HOCOCR keeps the bits above HCSTP" {
    var osc = unit();
    osc.write(base + oscsf.regs.hococr, 1, 0xF1);
    try std.testing.expect(!osc.running(oscsf.flag.hocosf));
    // ra8_cgc_use_hoco clears HCSTP out of whatever it read back.
    const held = osc.read(base + oscsf.regs.hococr, 1);
    osc.write(base + oscsf.regs.hococr, 1, held & ~@as(u32, oscsf.stop));
    try std.testing.expect(osc.running(oscsf.flag.hocosf));
    try std.testing.expectEqual(@as(u32, 0xF0), osc.read(base + oscsf.regs.hococr, 1));
}

test "starts and stops count only a stop bit that moved" {
    var osc = unit();
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    try std.testing.expectEqual(@as(u32, 1), osc.starts);
    try std.testing.expectEqual(@as(u32, 0), osc.stops);
    osc.write(base + oscsf.regs.mosccr, 1, 0x01);
    try std.testing.expectEqual(@as(u32, 1), osc.stops);
}

test "an untouched unit stays out of the report" {
    var osc = unit();
    try std.testing.expect(osc.quiet());
    _ = osc.read(base + oscsf.regs.oscsf, 1);
    try std.testing.expect(osc.quiet());
    osc.write(base + oscsf.regs.pllcr, 1, 0x00);
    try std.testing.expect(!osc.quiet());
}

test "the neighbours in the window are retained as written" {
    var osc = unit();
    // PLLCCR2 and friends are stored, not interpreted. 0x04C is outside the
    // window; 0x030 (MOSCWTCR) is inside it.
    osc.write(base + 0x06, 1, 0x5A);
    try std.testing.expectEqual(@as(u32, 0x5A), osc.read(base + 0x06, 1));
    try std.testing.expectEqual(@as(u32, 0), osc.readonly_writes);
}

test "a word load spanning OSCSF still reports the computed flags" {
    var osc = unit();
    osc.write(base + oscsf.regs.mosccr, 1, 0x00);
    const word = osc.read(base + oscsf.regs.oscsf, 4);
    try std.testing.expectEqual(
        @as(u32, oscsf.flag.hocosf | oscsf.flag.moscsf),
        word & 0xFF,
    );
}
