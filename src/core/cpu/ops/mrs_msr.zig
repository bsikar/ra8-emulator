//! MRS (T1) and MSR (T1, register): move a special register named by SYSm to
//! or from a core register. The semantics live in src/core/cpu/sysreg.zig.
//!
//! Left unclaimed, so the core stops rather than guess: SP or PC as the core
//! register, a SYSm the register file does not model, an MSR mask of 0b00, and
//! a mask other than 0b10 on a non-xPSR register.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const sysreg = @import("../sysreg.zig");

pub const encodings = struct {
    pub const mrs: u16 = 0xF3EF;
    /// MSR hw1 with Rn ([3:0]) masked out.
    pub const msr_mask: u16 = 0xFFF0;
    pub const msr: u16 = 0xF380;
    /// MRS hw2 = 0b1000 Rd SYSm.
    pub const mrs_hw2_mask: u16 = 0xF000;
    /// MSR hw2 = 0b10 0 0 mask 0b00 SYSm.
    pub const msr_hw2_mask: u16 = 0xF300;
    pub const hw2_space: u16 = 0x8000;
};

pub const group: op.Group = .{ .name = "mrs_msr", .decode = decode };

fn sysmOf(instr: Instr) u8 {
    return @truncate(instr.hw2);
}

fn maskOf(instr: Instr) u2 {
    return @intCast((instr.hw2 >> 10) & 0x3);
}

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    const n = sysmOf(instr);
    if (!sysreg.known(n)) return null;
    if (instr.hw1 == encodings.mrs and instr.hw2 & encodings.mrs_hw2_mask == encodings.hw2_space) {
        const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
        return if (spOrPc(rd)) null else mrs;
    }
    if (instr.hw1 & encodings.msr_mask != encodings.msr) return null;
    if (instr.hw2 & encodings.msr_hw2_mask != encodings.hw2_space) return null;
    if (spOrPc(@intCast(instr.hw1 & 0xF))) return null;
    const mask = maskOf(instr);
    if (mask == 0) return null;
    if (n > sysreg.sysm.xpsr_last and mask != 0b10) return null;
    return msr;
}

fn mrs(cpu: *Cpu, instr: Instr) op.Error!void {
    const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    cpu.regs.set(rd, sysreg.read(&cpu.regs, sysmOf(instr)));
}

fn msr(cpu: *Cpu, instr: Instr) op.Error!void {
    const value = cpu.regs.get(@intCast(instr.hw1 & 0xF));
    sysreg.write(&cpu.regs, sysmOf(instr), maskOf(instr), value);
}
