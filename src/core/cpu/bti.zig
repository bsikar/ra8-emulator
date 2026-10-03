//! EPSR.B tracking for Armv8.1-M branch target identification.
const regs = @import("regs.zig");
const Instr = @import("instr.zig").Instr;

pub const bit: u32 = 1 << 21;

/// BTI is selected independently for privileged and unprivileged execution.
pub fn enabled(r: *const regs.Regs, implements_bti: bool) bool {
    if (!implements_bti) return false;
    const unprivileged = !r.handlerMode() and r.control & regs.control_bits.npriv != 0;
    const control_bit = if (unprivileged) regs.control_bits.ubti_en else regs.control_bits.bti_en;
    return r.control & control_bit != 0;
}

/// A branch through a non-LR register requires a landing pad when enabled.
pub fn setForBranch(r: *regs.Regs, target_register: u4, implements_bti: bool) void {
    if (target_register != 14) setForAddress(r, implements_bti);
}

/// A load into PC sets the branch target flag when BTI is enabled.
pub fn setForAddress(r: *regs.Regs, implements_bti: bool) void {
    if (enabled(r, implements_bti)) r.xpsr |= bit;
}

/// BLX is a BTI setting instruction regardless of its source register.
pub fn setForCall(r: *regs.Regs, implements_bti: bool) void {
    if (enabled(r, implements_bti)) r.xpsr |= bit;
}

/// BTI and PACBTI are the landing pads a checked indirect branch may reach.
pub fn clearing(instr: Instr) bool {
    return instr.size == 4 and instr.hw1 == 0xF3AF and (instr.hw2 == 0x800F or instr.hw2 == 0x800D);
}

/// BKPT ignores EPSR.B; other executed instructions fault while it is set.
pub fn allowed(instr: Instr) bool {
    return clearing(instr) or (instr.size == 2 and instr.hw1 & 0xFF00 == 0xBE00);
}
