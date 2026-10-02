//! The saturating instructions with a plain binary immediate (T1): SSAT and
//! USAT. Rn is shifted (LSL, or ASR #1..31), then clamped to a signed range of
//! 1..32 bits or an unsigned range of 0..31 bits. A clamp sets the sticky
//! APSR.Q; nothing else in the flags changes.
//!
//! Left unclaimed: Rd or Rn of SP or PC (UNPREDICTABLE), and the ASR #0
//! encodings, which are SSAT16 and USAT16 from the DSP extension.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const xpsr_bits = @import("../regs.zig").xpsr_bits;

pub const encodings = struct {
    /// hw1 with sh ([5]) and Rn ([3:0]) masked out.
    pub const mask: u16 = 0xFFD0;
    pub const ssat: u16 = 0xF300;
    pub const usat: u16 = 0xF380;
    pub const sh: u16 = 0x0020;
    /// hw2[15] and hw2[5] are zero in both.
    pub const hw2_zero: u16 = 0x8020;
};

pub const group: op.Group = .{ .name = "saturate", .decode = decode };

pub const Fields = struct {
    unsigned: bool,
    asr: bool,
    rn: u4,
    rd: u4,
    amount: u5,
    /// sat_imm as encoded: the bit count minus one for SSAT, the count for USAT.
    sat_imm: u5,

    pub fn of(instr: Instr) ?Fields {
        if (instr.size != 4 or instr.hw2 & encodings.hw2_zero != 0) return null;
        const unsigned = switch (instr.hw1 & encodings.mask) {
            encodings.ssat => false,
            encodings.usat => true,
            else => return null,
        };
        const imm3: u5 = @intCast((instr.hw2 >> 12) & 0x7);
        const imm2: u5 = @intCast((instr.hw2 >> 6) & 0x3);
        return .{
            .unsigned = unsigned,
            .asr = instr.hw1 & encodings.sh != 0,
            .rn = @intCast(instr.hw1 & 0xF),
            .rd = @intCast((instr.hw2 >> 8) & 0xF),
            .amount = (imm3 << 2) | imm2,
            .sat_imm = @intCast(instr.hw2 & 0x1F),
        };
    }
};

fn spOrPc(n: u4) bool {
    return n == 13 or n == 15;
}

fn decode(instr: Instr) ?op.Exec {
    const f = Fields.of(instr) orelse return null;
    if (spOrPc(f.rd) or spOrPc(f.rn)) return null;
    if (f.asr and f.amount == 0) return null;
    return exec;
}

pub const Saturated = struct { value: u32, clamped: bool };

/// Clamps `operand` to the range `f` names.
pub fn saturate(f: Fields, operand: i32) Saturated {
    const wide: i64 = operand;
    const lo: i64, const hi: i64 = if (f.unsigned)
        .{ 0, (@as(i64, 1) << f.sat_imm) - 1 }
    else
        .{ -(@as(i64, 1) << f.sat_imm), (@as(i64, 1) << f.sat_imm) - 1 };
    const clamped = @max(lo, @min(hi, wide));
    const bits: u64 = @bitCast(clamped);
    return .{ .value = @truncate(bits), .clamped = clamped != wide };
}

/// Rn after the encoded shift, as a signed value.
pub fn shifted(f: Fields, rn: u32) i32 {
    const signed: i32 = @bitCast(rn);
    return if (f.asr) signed >> f.amount else @bitCast(rn << f.amount);
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = Fields.of(instr).?;
    const s = saturate(f, shifted(f, cpu.regs.get(f.rn)));
    cpu.regs.set(f.rd, s.value);
    if (s.clamped) cpu.regs.xpsr |= xpsr_bits.q;
}
