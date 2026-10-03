//! Exception return: what a branch to an EXC_RETURN value does in Handler
//! mode. The frame comes off the stack EXC_RETURN names, the registers and
//! xPSR it held come back, and the processor resumes in the mode it names.
const bus = @import("../bus.zig");
const regs_mod = @import("../regs.zig");
const Cpu = @import("../cpu.zig").Cpu;
const frame = @import("frame.zig");
const fp_frame = @import("fp_frame.zig");
const Fpscr = @import("../fpu/fpscr.zig").Fpscr;
const Vpr = @import("../mve/predicate.zig").Vpr;
const exc_return = @import("exc_return.zig");
const callee = @import("callee.zig");

/// SecureReturn: a Non-secure handler named a Secure exception (EXC_RETURN.ES
/// set), which the core takes as SecureFault INVER (RA8EMU-472).
pub const Error = bus.Error || error{ InvalidReturn, Integrity, SecureReturn };

/// The xPSR bits a return restores: the flags, ICI/IT, T, GE and IPSR.
/// Bit 9 is the frame's realignment marker, not state.
pub const restored: u32 = 0xFF0F_FDFF;

pub fn from(cpu: *Cpu, value: u32) Error!void {
    const target = exc_return.decode(value) orelse return error.InvalidReturn;
    if (target.secure and cpu.banked.current == .non_secure) return error.SecureReturn;
    // The return is made in the state the exception was taken to, then
    // switches to the state whose stack holds the frame (S).
    if (target.secure != (cpu.banked.current == .secure)) return error.InvalidReturn;
    cpu.banked.switchTo(&cpu.regs, if (target.secure_stack) .secure else .non_secure);
    const r = &cpu.regs;
    cpu.exclusive = null;
    var at = if (target.psp) r.psp else r.msp;
    if (target.secure_stack and !target.secure) {
        const hidden = try callee.pop(cpu.bus, at, target.fp);
        for (hidden.callee, 4..) |word, i| r.low[i] = word;
        at = hidden.sp;
    }
    const popped: frame.Popped = if (target.fp) blk: {
        const ext = try fp_frame.pop(cpu.bus, at);
        if (target.thread != (ext.frame[frame.slot.xpsr] & regs_mod.xpsr_bits.ipsr == 0)) return error.InvalidReturn;
        for (ext.fp.s, 0..) |word, i| cpu.fp.bank.writeS(@intCast(i), word);
        cpu.fp.fpscr = Fpscr.fromBits(ext.fp.fpscr);
        if (cpu.profile.mve) cpu.fp.vpr = vprFrom(ext.fp.vpr);
        break :blk .{ .frame = ext.frame, .sp = ext.sp };
    } else try frame.pop(cpu.bus, at);
    const f = popped.frame;
    // Returning to Thread mode with an exception number stacked, or to
    // Handler mode with none, is an INVPC UsageFault.
    if (target.thread != (f[frame.slot.xpsr] & regs_mod.xpsr_bits.ipsr == 0)) return error.InvalidReturn;
    if (target.psp) r.psp = popped.sp else r.msp = popped.sp;
    const spsel = regs_mod.control_bits.spsel;
    r.control = if (target.psp) r.control | spsel else r.control & ~spsel;
    const fpca = regs_mod.control_bits.fpca;
    r.control = if (target.fp) r.control | fpca else r.control & ~fpca;
    for (0..4) |i| r.low[i] = f[i];
    r.low[12] = f[frame.slot.r12];
    r.lr = f[frame.slot.lr];
    r.pc = f[frame.slot.return_address] & ~@as(u32, 1);
    r.xpsr = f[frame.slot.xpsr] & restored;
    cpu.event = true;
}

/// VPR as an extended-frame return restores it: bits 31:24 are reserved.
fn vprFrom(word: u32) Vpr {
    var vpr: Vpr = @bitCast(word);
    vpr.reserved = 0;
    return vpr;
}
