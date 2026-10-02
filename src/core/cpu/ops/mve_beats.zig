//! The CPU side of beat-wise MVE execution (RA8EMU-107): mve/beats.zig
//! applied to the core's VPR and the IT byte in its xPSR.
const Cpu = @import("../cpu.zig").Cpu;
const it_state = @import("../it_state.zig");
const mve = @import("../mve/all.zig");

fn itOf(cpu: *const Cpu) u8 {
    return it_state.get(cpu.regs.xpsr);
}

/// The byte lanes this instruction writes: VPT and ECI together.
pub fn mask(cpu: *const Cpu) u16 {
    return mve.beats.mask(cpu.fp.vpr, itOf(cpu));
}

/// The byte lanes of the beats ECI leaves to run.
pub fn pending(cpu: *const Cpu) u16 {
    return mve.beats.pending(itOf(cpu));
}

/// Writes Qd, keeping the lanes of beats ECI says already ran.
pub fn keep(cpu: *Cpu, qd: u3, value: u128) void {
    const old = mve.qreg.read(&cpu.fp.bank, qd);
    mve.qreg.write(&cpu.fp.bank, qd, mve.predicate.merge(old, value, pending(cpu)));
}

/// Retires the instruction: VPT advances over the beats that ran and
/// ECI moves on.
pub fn finish(cpu: *Cpu) void {
    const r = mve.beats.retire(cpu.fp.vpr, itOf(cpu));
    cpu.fp.vpr = r.vpr;
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, r.it);
}

/// Retires an instruction that is not predicated (VLD2/VLD4): only ECI
/// moves on.
pub fn finishEci(cpu: *Cpu) void {
    cpu.regs.xpsr = it_state.put(cpu.regs.xpsr, mve.eci.next(itOf(cpu)));
}
