//! Armv8.1-M scalar long shifts by an immediate: LSLL, LSRL and ASRL.
//!
//! Each shifts the 64-bit value RdaHi:RdaLo held in an even/odd register
//! pair and writes it back to the same pair. They sit in what Armv8-M left
//! as ORRS with the PC as the shifted operand (hw2[3:0] = 0b1111), so a core
//! without MVE, Unicorn included, reads them as that UNPREDICTABLE ORRS.
//! src/core/long_shift_hook.zig runs this arithmetic on the Unicorn path
//! instead, so lockstep checks the group like any other (RA8EMU-138).
//!
//! The fields, from the encoding:
//!   hw1 = 1110 1010 0101 RdaLo[3:1] 0
//!   hw2 = 0 imm3 RdaHi[3:1] 1 imm2 type 1111, type 00 LSLL, 01 LSRL, 10 ASRL
//! so RdaLo is always even and RdaHi always odd. None of the three writes
//! the flags.
//!
//! Left unclaimed for now (RA8EMU-96): a shift of zero, RdaHi = 0b1111 (the
//! single-register saturating shifts), type 0b11, hw1 bit 0 set, and the
//! register-shift forms.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const Kind = enum(u2) { lsll = 0, lsrl = 1, asrl = 2 };

pub const Fields = struct {
    lo: u4,
    hi: u4,
    amount: u6,
    kind: Kind,
};

pub const group: op.Group = .{ .name = "long_shift", .decode = decode, .oracle = true };

pub fn fields(instr: Instr) ?Fields {
    if (instr.size != 4) return null;
    if (instr.hw1 & 0xFFF1 != 0xEA50) return null;
    if (instr.hw2 & 0x810F != 0x010F) return null;
    const hi: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    if (hi == 0xF) return null;
    const kind_bits: u2 = @intCast((instr.hw2 >> 4) & 0x3);
    if (kind_bits == 0x3) return null;
    const imm3: u6 = @intCast((instr.hw2 >> 12) & 0x7);
    const imm2: u6 = @intCast((instr.hw2 >> 6) & 0x3);
    const amount = (imm3 << 2) | imm2;
    if (amount == 0) return null;
    return .{ .lo = @intCast(instr.hw1 & 0xE), .hi = hi, .amount = amount, .kind = @enumFromInt(kind_bits) };
}

fn decode(instr: Instr) ?op.Exec {
    _ = fields(instr) orelse return null;
    return exec;
}

/// The 64-bit result of shifting `value` the way `kind` says by `amount`,
/// 1 to 31.
pub fn shift(kind: Kind, value: u64, amount: u6) u64 {
    const n: u6 = amount;
    return switch (kind) {
        .lsll => value << n,
        .lsrl => value >> n,
        .asrl => @bitCast(@as(i64, @bitCast(value)) >> n),
    };
}

fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
    const f = fields(instr).?;
    const value = (@as(u64, cpu.regs.get(f.hi)) << 32) | cpu.regs.get(f.lo);
    const result = shift(f.kind, value, f.amount);
    cpu.regs.set(f.lo, @truncate(result));
    cpu.regs.set(f.hi, @truncate(result >> 32));
}
