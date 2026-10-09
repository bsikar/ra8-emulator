//! APSR.NZCV and the arithmetic that produces it, per the Arm ARM pseudocode
//! (AddWithCarry), plus the IT-block test the 16-bit data-processing forms
//! need: outside an IT block they set the flags, inside one they do not.
const regs = @import("regs.zig");

pub const bits = struct {
    pub const n: u32 = 1 << 31;
    pub const z: u32 = 1 << 30;
    pub const c: u32 = 1 << 29;
    pub const v: u32 = 1 << 28;
    /// EPSR.IT[1:0] at [26:25] and IT[7:2] at [15:10].
    pub const it: u32 = (0x3 << 25) | (0x3F << 10);
};

pub const Sum = struct {
    result: u32,
    carry: bool,
    overflow: bool,
};

/// AddWithCarry(x, y, carry_in).
pub fn addWithCarry(x: u32, y: u32, carry_in: bool) Sum {
    const wide = @as(u64, x) + @as(u64, y) + @intFromBool(carry_in);
    const result: u32 = @truncate(wide);
    const sx: i64 = @as(i32, @bitCast(x));
    const sy: i64 = @as(i32, @bitCast(y));
    const signed_sum = sx + sy + @intFromBool(carry_in);
    return .{
        .result = result,
        .carry = wide >> 32 != 0,
        .overflow = signed_sum != @as(i32, @bitCast(result)),
    };
}

pub fn carry(file: *const regs.Regs) bool {
    return file.xpsr & bits.c != 0;
}

pub fn inItBlock(file: *const regs.Regs) bool {
    return file.xpsr & bits.it != 0;
}

fn put(file: *regs.Regs, bit: u32, on: bool) void {
    file.xpsr = if (on) file.xpsr | bit else file.xpsr & ~bit;
}

pub fn setNZ(file: *regs.Regs, result: u32) void {
    put(file, bits.n, result & (1 << 31) != 0);
    put(file, bits.z, result == 0);
}

pub fn setNZC(file: *regs.Regs, result: u32, carry_out: bool) void {
    setNZ(file, result);
    put(file, bits.c, carry_out);
}

pub fn setNZCV(file: *regs.Regs, sum: Sum) void {
    setNZC(file, sum.result, sum.carry);
    put(file, bits.v, sum.overflow);
}
