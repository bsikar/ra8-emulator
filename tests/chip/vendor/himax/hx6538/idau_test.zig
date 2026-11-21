//! Covers src/chip/vendor/himax/hx6538/idau.zig: inverted HX bit-28 IDAU polarity.
const ra8 = @import("ra8");
const std = @import("std");

const hx_idau = ra8.chip.vendor.himax.hx6538.idau;
const memmap = ra8.chip.core.memmap;
const sau = ra8.chip.periph.sau;
const sau_attr = ra8.chip.periph.sau.attribution;

test "HX6538 IDAU polarity treats bit-28 set as Secure/Callable and bit-28 clear as Non-secure" {
    try std.testing.expectEqual(sau_attr.State.non_secure, hx_idau.answer(0x0000_0000).state);
    try std.testing.expectEqual(sau_attr.State.callable, hx_idau.answer(0x1000_0000).state);
    try std.testing.expectEqual(sau_attr.State.non_secure, hx_idau.answer(0x2400_0000).state);
    try std.testing.expectEqual(sau_attr.State.callable, hx_idau.answer(0x3400_0000).state);
    try std.testing.expectEqual(sau_attr.State.non_secure, hx_idau.answer(0x4400_A000).state);
    try std.testing.expectEqual(sau_attr.State.secure, hx_idau.answer(0x5400_A000).state);
    try std.testing.expectEqual(sau_attr.State.non_secure, hx_idau.answer(0x6000_0000).state);
    const ppb = hx_idau.answer(0xE000_ED00);
    try std.testing.expect(ppb.exempt);
}

test "SAU combines with HX6538 IDAU to permit NSC in 0x1... and keep 0x5... strictly Secure" {
    var unit = sau.Sau.init();
    unit.setRegions(8);
    _ = unit.observe(memmap.sau.ctrl, sau.field.ctrl_enable);
    // Region 0: 0x0000_0000..0x0FFF_FFFF Non-secure
    _ = unit.observe(memmap.sau.rnr, 0);
    _ = unit.observe(memmap.sau.rbar, 0x0000_0000);
    _ = unit.observe(memmap.sau.rlar, 0x0FFF_FFE1);
    // Region 1: 0x1000_1000..0x1000_1FFF Secure, NSC
    _ = unit.observe(memmap.sau.rnr, 1);
    _ = unit.observe(memmap.sau.rbar, 0x1000_1000);
    _ = unit.observe(memmap.sau.rlar, 0x1000_1FE3);
    // Region 2: attempt to mark Secure MMIO 0x5400_0000..0x5400_FFFF NS in SAU (IDAU must keep Secure)
    _ = unit.observe(memmap.sau.rnr, 2);
    _ = unit.observe(memmap.sau.rbar, 0x5400_0000);
    _ = unit.observe(memmap.sau.rlar, 0x5400_FFE1);

    const ns_itcm = sau_attr.attribute(&unit, hx_idau.answer(0x0000_0100), 0x0000_0100);
    const nsc_itcm = sau_attr.attribute(&unit, hx_idau.answer(0x1000_1000), 0x1000_1000);
    const sec_itcm = sau_attr.attribute(&unit, hx_idau.answer(0x1000_2000), 0x1000_2000);
    const sec_mmio = sau_attr.attribute(&unit, hx_idau.answer(0x5400_A000), 0x5400_A000);
    try std.testing.expectEqual(sau_attr.State.non_secure, ns_itcm.state);
    try std.testing.expectEqual(sau_attr.State.callable, nsc_itcm.state);
    try std.testing.expectEqual(sau_attr.State.secure, sec_itcm.state);
    try std.testing.expectEqual(sau_attr.State.secure, sec_mmio.state);
}
