//! BLXNS (T1), the Secure boot's one call into the Non-secure image. With
//! bit 0 of the target clear the core becomes Non-secure (Banked.switchTo,
//! as BXNS does), so Non-secure exceptions stack and return in their own
//! state; with bit 0 set it is a plain BLX and stays Secure (RA8EMU-32).
//! SP moves to the Non-secure vector table's initial stack when VTOR_NS
//! points at one, and LR keeps the address after the BLXNS (with the Thumb
//! bit) rather than FNC_RETURN, the way src/core/tz.zig models the call on
//! the Unicorn path: the Non-secure reset handler never returns.
//!
//! Left unclaimed: Rm of SP or PC, and the 32-bit space. BXNS is
//! src/core/cpu/ops/bxns.zig.
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
    const target = cpu.regs.get(rm);
    const entry = tz.enter(target, nonSecureStack(cpu), instr.address +% tz.encoding.width);
    if (target & 1 == 0) cpu.banked.switchTo(&cpu.regs, .non_secure);
    if (entry.sp) |stack| cpu.regs.setSp(stack);
    cpu.regs.lr = entry.lr;
    cpu.regs.bxWritePc(entry.pc);
}
