//! SEL (T1): each byte of Rd comes from Rn when its APSR.GE bit is set and
//! from Rm when it is clear. GE is what the parallel adds and subtracts in
//! ops/parallel.zig leave behind. No flags change.
//!
//! Left unclaimed: SP or PC in Rd, Rn or Rm (UNPREDICTABLE).
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const xpsr_bits = @import("../regs.zig").xpsr_bits;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const sel: u16 = 0xFAA0;
    /// hw2 with Rd ([11:8]) and Rm ([3:0]) masked out.
    pub const hw2_mask: u16 = 0xF0F0;
    pub const hw2_fixed: u16 = 0xF080;
};

pub const group: op.Group = .{ .name = "sel", .decode = decode };

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.sel) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2_fixed) return null;
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    const rm: u4 = @intCast(instr.hw2 & 0xF);
    if (spOrPc(rd) or spOrPc(rn) or spOrPc(rm)) return null;
    return exec;
}

/// Rd for GE bits `ge`, Rn = `n` and Rm = `m`.
pub fn result(ge: u4, n: u32, m: u32) u32 {
    var mask: u32 = 0;
    var i: u3 = 0;
    while (i < 4) : (i += 1) {
        if ((ge >> @intCast(i)) & 1 != 0) mask |= @as(u32, 0xFF) << (@as(u5, i) * 8);
    }
    return (n & mask) | (m & ~mask);
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const ge: u4 = @truncate(cpu.regs.xpsr >> xpsr_bits.ge_shift);
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    const rm: u4 = @intCast(instr.hw2 & 0xF);
    cpu.regs.set(rd, result(ge, cpu.regs.get(rn), cpu.regs.get(rm)));
}
