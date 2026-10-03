//! Covers src/core/cpu/lockstep/attribution.zig.
const std = @import("std");
const ra8 = @import("ra8");
const sau = ra8.periph.sau;
const lockstep_attribution = ra8.core.cpu.lockstep.attribution;
const State = ra8.core.cpu.cpu.attribution.State;

const enable: u32 = 1 << 0;
const nsc: u32 = 1 << 1;

/// The SAU the tz_nsc_cgc_usb pair programs, cut down to its veneer page
/// and its Non-secure SRAM.
fn pairSau() sau.Sau {
    var unit = sau.Sau{ .ctrl = enable };
    unit.table[0] = sau.Region.fromPair(0x0200_3500, 0x0200_35E0 | nsc | enable);
    unit.table[1] = sau.Region.fromPair(0x3210_0000, 0x3211_FFE0 | enable);
    return unit;
}

test "an SG veneer in the Secure image is Non-secure callable" {
    const unit = pairSau();
    var guard = lockstep_attribution.over(&unit);
    try std.testing.expectEqual(State.callable, guard.source().of(0x0200_3550));
}

test "the Non-secure half's code is Non-secure" {
    const unit = pairSau();
    var guard = lockstep_attribution.over(&unit);
    try std.testing.expectEqual(State.non_secure, guard.source().of(0x3210_0060));
}

test "Secure code outside the veneers stays Secure" {
    const unit = pairSau();
    var guard = lockstep_attribution.over(&unit);
    try std.testing.expectEqual(State.secure, guard.source().of(0x0200_0608));
}

test "with the SAU off nothing is callable" {
    const unit = sau.Sau.init();
    var guard = lockstep_attribution.over(&unit);
    try std.testing.expectEqual(State.secure, guard.source().of(0x0200_3550));
}
