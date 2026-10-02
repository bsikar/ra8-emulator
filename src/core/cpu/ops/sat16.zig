//! SSAT16 and USAT16 (T1): each halfword of Rn saturated on its own. SSAT16
//! clamps to a signed range of sat_imm + 1 bits, USAT16 to an unsigned range
//! of sat_imm bits. Any clamp sets APSR.Q. These are the "ASR #0" rows that
//! ops/saturate.zig leaves.
//!
//! Left unclaimed: SP or PC in Rd or Rn (UNPREDICTABLE), and any set bit in
//! hw2[15], imm3, imm2 or hw2[5:4].
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const xpsr_bits = @import("../regs.zig").xpsr_bits;

pub const encodings = struct {
    /// hw1 with Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFF0;
    pub const ssat16: u16 = 0xF320;
    pub const usat16: u16 = 0xF3A0;
    /// hw2 bits that must be zero: [15], imm3 [14:12], imm2 [7:6], [5:4].
    pub const hw2_zero: u16 = 0xF0F0;
};

pub const group: op.Group = .{ .name = "sat16", .decode = decode };

pub const Fields = struct {
    signed: bool,
    rn: u4,
    rd: u4,
    sat_imm: u4,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_zero != 0) return null;
        const signed = switch (instr.hw1 & encodings.mask) {
            encodings.ssat16 => true,
            encodings.usat16 => false,
            else => return null,
        };
        return .{
            .signed = signed,
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .sat_imm = @intCast(instr.hw2 & 0xF),
        };
    }
};

pub const Result = struct { value: u32, clamped: bool };

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rn)) return null;
    return exec;
}

fn clampHalf(f: Fields, half: u16) struct { u16, bool } {
    const v: i32 = @as(i16, @bitCast(half));
    const lo: i32 = if (f.signed) -(@as(i32, 1) << f.sat_imm) else 0;
    const hi: i32 = (@as(i32, 1) << f.sat_imm) - 1;
    const c = @max(lo, @min(hi, v));
    return .{ @truncate(@as(u32, @bitCast(c))), c != v };
}

/// Rd for `f` with Rn = `rn`.
pub fn result(f: Fields, rn: u32) Result {
    const lo = clampHalf(f, @truncate(rn));
    const hi = clampHalf(f, @truncate(rn >> 16));
    return .{ .value = (@as(u32, hi[0]) << 16) | lo[0], .clamped = lo[1] or hi[1] };
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const r = result(f, cpu.regs.get(f.rn));
    cpu.regs.set(f.rd, r.value);
    if (r.clamped) cpu.regs.xpsr |= xpsr_bits.q;
}
