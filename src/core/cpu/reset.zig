//! Reset from the vector table: what the processor does before its first
//! instruction. Word 0 is the initial Main stack pointer and word 1 is the
//! reset handler, whose bit 0 becomes EPSR.T.
const bus = @import("bus.zig");
const regs_mod = @import("regs.zig");

/// LR after reset. All ones is an illegal exception return, so a reset
/// handler that returns faults instead of running off into memory.
pub const lr_at_reset: u32 = 0xFFFF_FFFF;

pub fn fromVectorTable(regs: *regs_mod.Regs, from: bus.Bus, vtor: u32) bus.Error!void {
    const initial_sp = try from.readWord(vtor);
    const handler = try from.readWord(vtor +% 4);
    regs.* = .{};
    regs.msp = initial_sp & ~@as(u32, 3);
    regs.lr = lr_at_reset;
    regs.pc = handler & ~@as(u32, 1);
    if (handler & 1 != 0) regs.xpsr = regs_mod.xpsr_bits.thumb;
}
