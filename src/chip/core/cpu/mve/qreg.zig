//! MVE's Q0-Q7 (RA8EMU-25), aliased onto the FP bank as the Arm ARM
//! (DDI0553) defines it: Q[n] is D[2n+1]:D[2n], so S[4n] holds bytes 0-3.
//! Elements are numbered from the low end, the way Elem[] numbers them,
//! and an element index must be below `lanes(size)`.
const Bank = @import("../fpu/bank.zig").Bank;

pub const Size = enum(u2) { byte = 0, half = 1, word = 2 };

/// The element width in bits: 8, 16 or 32.
pub fn bits(size: Size) u8 {
    return @as(u8, 8) << @backingInt(size);
}

/// How many elements of that size a 128-bit vector holds: 16, 8 or 4.
pub fn lanes(size: Size) u8 {
    return @as(u8, 16) >> @backingInt(size);
}

pub fn read(bank: *const Bank, q: u3) u128 {
    const base: u5 = @as(u5, q) * 4;
    var value: u128 = 0;
    for (0..4) |k| value |= @as(u128, bank.s[base + k]) << @intCast(32 * k);
    return value;
}

pub fn write(bank: *Bank, q: u3, value: u128) void {
    const base: u5 = @as(u5, q) * 4;
    for (0..4) |k| bank.s[base + k] = @truncate(value >> @intCast(32 * k));
}

fn mask(size: Size) u128 {
    return (@as(u128, 1) << @intCast(bits(size))) - 1;
}

fn shift(size: Size, e: u8) u7 {
    return @intCast(@as(u16, e) * bits(size));
}

/// Element `e`, zero-extended to 32 bits.
pub fn elem(value: u128, size: Size, e: u8) u32 {
    return @truncate(value >> shift(size, e) & mask(size));
}

/// `value` with element `e` replaced by the low bits of `x`.
pub fn setElem(value: u128, size: Size, e: u8, x: u32) u128 {
    const s = shift(size, e);
    const cleared = value & ~(mask(size) << s);
    return cleared | ((@as(u128, x) & mask(size)) << s);
}
