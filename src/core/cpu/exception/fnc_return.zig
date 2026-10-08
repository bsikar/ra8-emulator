//! FunctionReturn() (RA8EMU-167): the way back from a Non-secure callee a
//! BLXNS called. A branch to FNC_RETURN pops the frame BLXNS left on the
//! Secure stack for the current mode (MSP_S in Handler mode, else the one
//! CONTROL_S.SPSEL picks): the return address, then a partial RETPSR with
//! IPSR and SFPA at bit 20.
//!
//! The frame must agree with the mode: Thread mode with RETPSR.Exception
//! zero, or Handler mode (IPSR 1, as BLXNS left it) with it nonzero.
//! Anything else is a UsageFault INVPC in the current state, as the Arm ARM
//! (DDI0553) pseudocode has it, and the frame stays. A good frame restores
//! IPSR and CONTROL_S.SFPA, moves the stack past it, makes the core Secure
//! and branches, bit 0 of the address becoming EPSR.T.
const bus = @import("../bus.zig");
const Cpu = @import("../cpu.zig").Cpu;
const regs = @import("../regs.zig");
const xpsr_bits = regs.xpsr_bits;
const control_bits = regs.control_bits;

/// RETPSR.SFPA in the frame BLXNS pushes.
pub const retpsr_sfpa: u32 = 1 << 20;

pub const Error = bus.Error || error{InconsistentFrame};

pub fn from(cpu: *Cpu) Error!void {
    const ipsr = cpu.regs.xpsr & xpsr_bits.ipsr;
    const secure = cpu.banked.bank(&cpu.regs, .secure);
    const process = ipsr == 0 and secure.control & control_bits.spsel != 0;
    const frame = if (process) secure.psp else secure.msp;
    const target = try cpu.bus.readWord(frame);
    const retpsr = try cpu.bus.readWord(frame +% 4);
    const exception = retpsr & xpsr_bits.ipsr;
    if (!consistent(ipsr, exception)) return error.InconsistentFrame;
    cpu.banked.switchTo(&cpu.regs, .secure);
    if (process) cpu.regs.setPsp(frame +% 8) else cpu.regs.setMsp(frame +% 8);
    cpu.regs.xpsr = (cpu.regs.xpsr & ~xpsr_bits.ipsr) | exception;
    if (retpsr & retpsr_sfpa != 0)
        cpu.regs.control |= control_bits.sfpa
    else
        cpu.regs.control &= ~control_bits.sfpa;
    const thumb = xpsr_bits.thumb;
    cpu.regs.xpsr = if (target & 1 != 0) cpu.regs.xpsr | thumb else cpu.regs.xpsr & ~thumb;
    cpu.regs.pc = target & ~@as(u32, 1);
}

/// Whether a frame's RETPSR.Exception fits the mode the return runs in.
pub fn consistent(ipsr: u32, exception: u32) bool {
    return (ipsr == 0 and exception == 0) or (ipsr == 1 and exception != 0);
}
