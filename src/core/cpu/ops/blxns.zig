//! BLXNS (T1), the Secure boot's one call into the Non-secure image, taken
//! the way src/core/tz.zig models it on the Unicorn path: in this emulator's
//! single flat domain the call is a branch. The core stays Secure, moves SP
//! to the Non-secure vector table's initial stack when VTOR_NS points at one,
//! and leaves the address after the BLXNS (with the Thumb bit) in LR so a
//! callee that returns lands where the architecture would put it.
//!
//! Left unclaimed: BXNS, Rm of SP or PC, and the 32-bit space.
//!
//! Not checked against Unicorn: its side is the tz hook, which performs the
//! same branch and stops the run, so lockstep brings Unicorn to this state.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const tz = @import("../../tz.zig");
const memmap = @import("../../memmap.zig");

pub const group: op.Group = .{ .name = "blxns", .decode = decode, .oracle = false };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2) return null;
    const rm = tz.decode(instr.hw1) orelse return null;
    if (rm == 13 or rm == 15) return null;
    return call;
}

/// The initial stack in the Non-secure vector table, or null when VTOR_NS
/// is clear or either word cannot be read.
pub fn nonSecureStack(cpu: *const Cpu) ?u32 {
    const base = cpu.bus.readWord(memmap.scb.vtor_ns) catch return null;
    if (base == 0) return null;
    return cpu.bus.readWord(base) catch null;
}

fn call(cpu: *Cpu, instr: Instr) op.Error!void {
    const rm = tz.decode(instr.hw1).?;
    const entry = tz.enter(cpu.regs.get(rm), nonSecureStack(cpu), instr.address +% tz.encoding.width);
    if (entry.sp) |stack| cpu.regs.setSp(stack);
    cpu.regs.lr = entry.lr;
    cpu.regs.bxWritePc(entry.pc);
}
