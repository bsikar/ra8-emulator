//! DebugMonitor, exception 12, as the interrupt controller takes it.
//!
//! With halting debug off and DEMCR.MON_EN set, the debug core turns an FPB
//! or DWT event into DEMCR.MON_PEND and latches DFSR (src/session/step_hook.zig).
//! This file is the controller's half: MON_PEND with MON_EN is a pending
//! exception 12 at SHPR3 PRI_12, entry clears MON_PEND, and SHCSR.MONITORACT
//! is set while the handler runs (DDI0553 B3.6, D1.2.42).

const memmap = @import("../core/memmap.zig");
const dcb = @import("dcb.zig");
const Candidate = @import("candidate.zig").Candidate;

/// The DebugMonitor exception number.
pub const number: u16 = 12;
/// SHCSR.MONITORACT: DebugMonitor is active.
pub const shcsr_monitoract: u32 = 1 << 8;

/// DebugMonitor as a candidate when DEMCR has both MON_EN and MON_PEND set.
pub fn pending(core: anytype) !?Candidate {
    const demcr = try core.readWord(memmap.scb.demcr);
    const wanted = dcb.demcr_bits.mon_en | dcb.demcr_bits.mon_pend;
    if (demcr & wanted != wanted) return null;
    const shpr3 = try core.readWord(memmap.scb.shpr3);
    return .{ .number = number, .priority = @truncate(shpr3) };
}

/// Entry takes the pend: clear DEMCR.MON_PEND.
pub fn clear(core: anytype) !void {
    const demcr = try core.readWord(memmap.scb.demcr);
    try core.writeWord(memmap.scb.demcr, demcr & ~dcb.demcr_bits.mon_pend);
}

/// Set or clear SHCSR.MONITORACT on entry and return.
pub fn setActive(core: anytype, active: bool) !void {
    const shcsr = try core.readWord(memmap.scb.shcsr);
    const next = if (active) shcsr | shcsr_monitoract else shcsr & ~shcsr_monitoract;
    try core.writeWord(memmap.scb.shcsr, next);
}
