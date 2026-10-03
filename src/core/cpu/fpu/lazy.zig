//! PreserveFPState() (RA8EMU-163): the deferred half of lazy FP stacking.
//! With FPCCR.LSPEN set, exception entry reserves the FP part of the frame
//! and records its address in FPCAR with FPCCR.LSPACT set; the first FP
//! instruction that runs afterwards writes S0-S15, FPSCR and (Armv8.1-M
//! with MVE) VPR into that space and clears LSPACT. Offsets are from FPCAR,
//! per the Arm ARM (DDI0553) extended frame: S0 at 0, FPSCR at 0x40, VPR at
//! 0x44.
//!
//! Not modelled yet: the permission and MPU checks PreserveFPState makes
//! with FPCCR.USER/S/THREAD, faults during lazy stacking (the *RDY bits),
//! SPLIMVIOL, and the Secure S16-S31 words (RA8EMU-165).
const std = @import("std");
const bus = @import("../bus.zig");
const State = @import("state.zig").State;

pub const offset = struct {
    pub const s0: u32 = 0x00;
    pub const fpscr: u32 = 0x40;
    pub const vpr: u32 = 0x44;
};

/// Lazy preservation is pending: entry reserved the space, nothing wrote it.
pub fn pending(state: *const State) bool {
    return state.context.fpccr.lspact == 1;
}

/// Write the FP context into the space FPCAR names and clear LSPACT.
pub fn preserve(to: bus.Bus, state: *State) bus.Error!void {
    const at = state.context.fpcar;
    for (0..16) |i| {
        const n: u5 = @intCast(i);
        try putWord(to, at +% offset.s0 +% @as(u32, n) * 4, state.bank.readS(n));
    }
    try putWord(to, at +% offset.fpscr, state.fpscr.bits());
    try putWord(to, at +% offset.vpr, @bitCast(state.vpr));
    state.context.fpccr.lspact = 0;
}

fn putWord(to: bus.Bus, address: u32, value: u32) bus.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try to.write(address, &bytes);
}
