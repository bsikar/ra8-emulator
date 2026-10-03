//! BLXNS (T1), the Secure boot's one call into the Non-secure image. With
//! bit 0 of the target clear the core becomes Non-secure (Banked.switchTo,
//! as BXNS does), so Non-secure exceptions stack and return in their own
//! state; with bit 0 set it is a plain BLX and stays Secure (RA8EMU-32).
//! SP moves to the Non-secure vector table's initial stack when VTOR_NS
//! points at one.
//!
//! A call into Non-secure code first pushes the return frame on the Secure
//! stack (RA8EMU-171): the address after the BLXNS with the Thumb bit, then
//! a partial RETPSR holding IPSR and CONTROL_S.SFPA at bit 20. LR becomes
//! FNC_RETURN, IPSR reads 1 in Handler mode so Non-secure code never sees
//! the Secure exception number, and SFPA clears. A frame below the stack
//! limit is a stack overflow and changes nothing.
//!
//! Left unclaimed: Rm of SP or PC, and the 32-bit space. BXNS is
//! src/core/cpu/ops/bxns.zig.
//!
//! Not checked against Unicorn: its side is the tz hook, which performs the
//! same branch and stops the run, so lockstep brings Unicorn to this state.
const std = @import("std");
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const tz = @import("../../tz.zig");
const memmap = @import("../../memmap.zig");
const regs = @import("../regs.zig");
const xpsr_bits = regs.xpsr_bits;
const control_bits = regs.control_bits;

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

/// What BLXNS leaves in LR for a call into Non-secure code.
pub const fnc_return: u32 = 0xFEFF_FFFF;
/// RETPSR.SFPA in the frame BLXNS pushes.
pub const retpsr_sfpa = @import("../exception/fnc_return.zig").retpsr_sfpa;

fn call(cpu: *Cpu, instr: Instr) op.Error!void {
    const rm = tz.decode(instr.hw1).?;
    const target = cpu.regs.get(rm);
    const entry = tz.enter(target, nonSecureStack(cpu), instr.address +% tz.encoding.width);
    if (target & 1 != 0) {
        cpu.regs.lr = entry.lr;
        return cpu.regs.bxWritePc(entry.pc);
    }
    try pushReturn(cpu, entry.lr);
    cpu.banked.switchTo(&cpu.regs, .non_secure);
    if (entry.sp) |stack| cpu.regs.setSp(stack);
    cpu.regs.lr = fnc_return;
    cpu.regs.bxWritePc(entry.pc);
}

/// The frame FNC_RETURN pops later, on the Secure stack in use.
fn pushReturn(cpu: *Cpu, after: u32) op.Error!void {
    const ipsr = cpu.regs.xpsr & xpsr_bits.ipsr;
    const sfpa: u32 = if (cpu.regs.control & control_bits.sfpa != 0) retpsr_sfpa else 0;
    const frame = cpu.regs.sp() -% 8;
    if (frame < cpu.regs.spLimit()) return error.StackOverflow;
    try putWord(cpu, frame, after);
    try putWord(cpu, frame +% 4, ipsr | sfpa);
    cpu.regs.setSp(frame);
    if (ipsr != 0) cpu.regs.xpsr = (cpu.regs.xpsr & ~xpsr_bits.ipsr) | 1;
    cpu.regs.control &= ~control_bits.sfpa;
}

fn putWord(cpu: *Cpu, address: u32, value: u32) op.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try cpu.bus.write(address, &bytes);
}
