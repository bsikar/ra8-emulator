//! PreserveFPState() (RA8EMU-163): the deferred half of lazy FP stacking.
//! With FPCCR.LSPEN set, exception entry reserves the FP part of the frame
//! and records its address in FPCAR with FPCCR.LSPACT set; the first FP
//! instruction that runs afterwards writes S0-S15, FPSCR and (Armv8.1-M
//! with MVE) VPR into that space and clears LSPACT. Offsets are from FPCAR,
//! per the Arm ARM (DDI0553) extended frame: S0 at 0, FPSCR at 0x40, VPR at
//! 0x44.
//!
//! The push is made in the Security state FPCCR.S recorded, not the running
//! one (RA8EMU-475): a Non-secure context (S clear) may only land in
//! Non-secure memory, and anything else is LSPERR, a SecureFault that
//! reports FPCAR in SFAR. A Secure context may land anywhere, so the data
//! gate, which judges by the running state, is held off for the push.
//!
//! Not modelled yet: the privilege and MPU checks PreserveFPState makes
//! with FPCCR.USER/THREAD, faults during lazy stacking (the *RDY bits),
//! SPLIMVIOL. A Secure context (FPCCR.S) with FPCCR.TS set also writes
//! S16-S31 from 0x48 (RA8EMU-165).
const std = @import("std");
const bus = @import("../bus.zig");
const State = @import("state.zig").State;

pub const offset = struct {
    pub const s0: u32 = 0x00;
    pub const fpscr: u32 = 0x40;
    pub const vpr: u32 = 0x44;
    pub const s16: u32 = 0x48;
};

/// Lazy preservation is pending: entry reserved the space, nothing wrote it.
pub fn pending(state: *const State) bool {
    return state.context.fpccr.lspact == 1;
}

/// LazyPreserveError: a Non-secure context's push reached memory that is
/// not Non-secure; the core takes it as SecureFault LSPERR.
pub const Error = bus.Error || error{LazyPreserveError};

/// Write the FP context into the space FPCAR names and clear LSPACT. When
/// the entry that armed it hit the stack limit (FPCCR.SPLIMVIOL) nothing is
/// written: the space was never reserved (RA8EMU-621).
pub fn preserve(to: bus.Bus, state: *State) Error!void {
    if (state.context.fpccr.splimviol == 1) {
        state.context.fpccr.lspact = 0;
        return;
    }
    const gate = to.gate orelse return write(to, state);
    if (state.context.fpccr.s == 0 and !nonSecure(gate.source, state.context.fpcar))
        return error.LazyPreserveError;
    const was = gate.armed;
    gate.armed = false;
    defer gate.armed = was;
    return write(to, state);
}

/// Whether the whole space at `at` is Non-secure. Regions are 32-byte
/// granular and the space is 0x48 bytes, so both ends and the middle cover it.
fn nonSecure(source: anytype, at: u32) bool {
    for ([_]u32{ at, at +% 0x20, at +% offset.vpr }) |word| {
        if (source.of(word) != .non_secure) return false;
    }
    return true;
}

fn write(to: bus.Bus, state: *State) bus.Error!void {
    const at = state.context.fpcar;
    for (0..16) |i| {
        const n: u5 = @intCast(i);
        try putWord(to, at +% offset.s0 +% @as(u32, n) * 4, state.bank.readS(n));
    }
    try putWord(to, at +% offset.fpscr, state.fpscr.bits());
    try putWord(to, at +% offset.vpr, @bitCast(state.vpr));
    if (state.context.fpccr.ts == 1 and state.context.fpccr.s == 1) {
        for (16..32) |i| {
            const n: u5 = @intCast(i);
            try putWord(to, at +% offset.s16 +% @as(u32, n - 16) * 4, state.bank.readS(n));
        }
    }
    state.context.fpccr.lspact = 0;
}

fn putWord(to: bus.Bus, address: u32, value: u32) bus.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try to.write(address, &bytes);
}
