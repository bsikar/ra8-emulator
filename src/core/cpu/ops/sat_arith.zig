//! QADD, QDADD, QSUB and QDSUB (T1): signed 32-bit saturating add and
//! subtract. QADD is Rm + Rn, QSUB is Rm - Rn, and the D forms first double
//! Rn with saturation. Any clamp, including the doubling, sets APSR.Q.
//!
//! Left unclaimed: SP or PC in Rd, Rn or Rm (UNPREDICTABLE).
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const xpsr_bits = @import("../regs.zig").xpsr_bits;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const space: u16 = 0xFA80;
    /// hw2 with Rd ([11:8]), op2 ([5:4]) and Rm ([3:0]) masked out.
    pub const hw2_mask: u16 = 0xF0C0;
    pub const hw2_fixed: u16 = 0xF080;
};

/// op2 (hw2[5:4]).
pub const Kind = enum(u2) { qadd = 0, qdadd = 1, qsub = 2, qdsub = 3 };

pub const group: op.Group = .{ .name = "sat_arith", .decode = decode };

pub const Result = struct { value: u32, saturated: bool };

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & encodings.mask != encodings.space) return null;
    if (instr.hw2 & encodings.hw2_mask != encodings.hw2_fixed) return null;
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    const rm: u4 = @intCast(instr.hw2 & 0xF);
    if (spOrPc(rd) or spOrPc(rn) or spOrPc(rm)) return null;
    return exec;
}

fn signedSat(v: i64) Result {
    const lo: i64 = @as(i32, @bitCast(@as(u32, 0x8000_0000)));
    const hi: i64 = 0x7FFF_FFFF;
    const c = @max(lo, @min(hi, v));
    return .{ .value = @bitCast(@as(i32, @intCast(c))), .saturated = c != v };
}

/// Rd for `kind` with Rm = `m` and Rn = `n`.
pub fn compute(kind: Kind, m: u32, n: u32) Result {
    const sm: i64 = @as(i32, @bitCast(m));
    var sn: i64 = @as(i32, @bitCast(n));
    var doubled_sat = false;
    if (kind == .qdadd or kind == .qdsub) {
        const d = signedSat(sn * 2);
        sn = @as(i32, @bitCast(d.value));
        doubled_sat = d.saturated;
    }
    const sub = kind == .qsub or kind == .qdsub;
    const r = signedSat(if (sub) sm - sn else sm + sn);
    return .{ .value = r.value, .saturated = r.saturated or doubled_sat };
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const kind: Kind = @enumFromInt((instr.hw2 >> 4) & 0x3);
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    const rm: u4 = @intCast(instr.hw2 & 0xF);
    const r = compute(kind, cpu.regs.get(rm), cpu.regs.get(rn));
    cpu.regs.set(rd, r.value);
    if (r.saturated) cpu.regs.xpsr |= xpsr_bits.q;
}
