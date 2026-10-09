//! CPS (T1): CPSIE and CPSID on PRIMASK (I) and FAULTMASK (F).
//!
//! Only privileged code changes either mask; unprivileged Thread mode runs
//! it as a NOP. FAULTMASK is not raised from NMI or HardFault, whose
//! priority is already -2 or -1. An encoding with neither I nor F, or with
//! the should-be-zero bit 3 set, is left unclaimed.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const regs = @import("../regs.zig");

pub const encodings = struct {
    /// hw1 with im ([4]), I ([1]) and F ([0]) masked out.
    pub const mask: u16 = 0xFFE8;
    pub const cps: u16 = 0xB660;
    pub const disable: u16 = 1 << 4;
    pub const i: u16 = 1 << 1;
    pub const f: u16 = 1 << 0;
};

pub const exceptions = struct {
    pub const nmi: u32 = 2;
    pub const hard_fault: u32 = 3;
};

pub const group: op.Group = .{ .name = "cps", .decode = decode };

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 2 or instr.hw1 & encodings.mask != encodings.cps) return null;
    if (instr.hw1 & (encodings.i | encodings.f) == 0) return null;
    return exec;
}

pub fn privileged(file: *const regs.Regs) bool {
    return file.handlerMode() or file.control & regs.control_bits.npriv == 0;
}

fn mayRaiseFaultmask(file: *const regs.Regs) bool {
    const exception = file.xpsr & regs.xpsr_bits.ipsr;
    return exception != exceptions.nmi and exception != exceptions.hard_fault;
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const file = &cpu.regs;
    if (!privileged(file)) return;
    const disable = instr.hw1 & encodings.disable != 0;
    if (instr.hw1 & encodings.i != 0) file.primask = @intFromBool(disable);
    if (instr.hw1 & encodings.f != 0) {
        if (!disable) file.faultmask = 0 else if (mayRaiseFaultmask(file)) file.faultmask = 1;
    }
}
