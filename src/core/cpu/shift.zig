//! Shift_C from the Arm ARM: a value shifted by an amount, and the carry the
//! last bit shifted out leaves. An amount of zero returns the value and the
//! carry unchanged. Immediate shifts decode their amount with `immAmount`
//! first, because LSR and ASR #0 encode a shift of 32.
pub const Kind = enum(u2) { lsl = 0, lsr = 1, asr = 2, ror = 3 };

pub const Shifted = struct {
    result: u32,
    carry: bool,
};

/// DecodeImmShift for the LSL/LSR/ASR forms: imm5 of zero means 32 for LSR
/// and ASR, and stays zero for LSL.
pub fn immAmount(kind: Kind, imm5: u5) u6 {
    if (imm5 == 0 and (kind == .lsr or kind == .asr)) return 32;
    return imm5;
}

pub fn shiftC(value: u32, kind: Kind, amount: u32, carry_in: bool) Shifted {
    if (amount == 0) return .{ .result = value, .carry = carry_in };
    return switch (kind) {
        .lsl => lsl(value, amount),
        .lsr => lsr(value, amount),
        .asr => asr(value, amount),
        .ror => ror(value, amount),
    };
}

fn bit(value: u32, n: u32) bool {
    return (value >> @intCast(n)) & 1 != 0;
}

fn lsl(value: u32, amount: u32) Shifted {
    if (amount > 32) return .{ .result = 0, .carry = false };
    if (amount == 32) return .{ .result = 0, .carry = bit(value, 0) };
    return .{ .result = value << @intCast(amount), .carry = bit(value, 32 - amount) };
}

fn lsr(value: u32, amount: u32) Shifted {
    if (amount > 32) return .{ .result = 0, .carry = false };
    if (amount == 32) return .{ .result = 0, .carry = bit(value, 31) };
    return .{ .result = value >> @intCast(amount), .carry = bit(value, amount - 1) };
}

fn asr(value: u32, amount: u32) Shifted {
    const signed: i32 = @bitCast(value);
    if (amount >= 32) return .{ .result = @bitCast(signed >> 31), .carry = bit(value, 31) };
    return .{ .result = @bitCast(signed >> @intCast(amount)), .carry = bit(value, amount - 1) };
}

fn ror(value: u32, amount: u32) Shifted {
    const n: u5 = @intCast(amount % 32);
    const result = if (n == 0) value else (value >> n) | (value << @intCast(32 - @as(u6, n)));
    return .{ .result = result, .carry = bit(result, 31) };
}

/// RRX: a rotate right by one through the carry flag, what ROR #0 encodes.
pub fn rrx(value: u32, carry_in: bool) Shifted {
    const top: u32 = if (carry_in) 1 << 31 else 0;
    return .{ .result = top | (value >> 1), .carry = value & 1 != 0 };
}

/// DecodeImmShift then Shift_C for a shift field of the 32-bit register
/// forms: type and imm5, where ROR #0 means RRX.
pub fn immShiftC(value: u32, kind: Kind, imm5: u5, carry_in: bool) Shifted {
    if (kind == .ror and imm5 == 0) return rrx(value, carry_in);
    return shiftC(value, kind, immAmount(kind, imm5), carry_in);
}
