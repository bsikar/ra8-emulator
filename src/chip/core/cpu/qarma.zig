//! The QARMA5 block transform used by Armv8.1-M pointer authentication.
//! The 32-bit PAC is the low half of the transform of the zero-extended
//! pointer, keyed and tweaked by the zero-extended modifier.

pub const Key = [4]u32;

const round_constants = [_]u64{
    0x0000_0000_0000_0000,
    0x1319_8A2E_0370_7344,
    0xA409_3822_299F_31D0,
    0x082E_FA98_EC4E_6C89,
    0x4528_21E6_38D0_1377,
};
const alpha: u64 = 0xC0AC_29B7_C97C_50DD;

pub fn pac(pointer: u32, modifier: u32, words: Key) u32 {
    return @truncate(compute(pointer, modifier, words));
}

pub fn compute(data: u64, modifier: u64, words: Key) u64 {
    const key0: u64 = (@as(u64, words[3]) << 32) | words[2];
    const key1: u64 = (@as(u64, words[1]) << 32) | words[0];
    const modk0 = (key0 << 63) | ((key0 >> 1) ^ (key0 >> 63));
    var tweak: u64 = modifier;
    var value: u64 = data ^ key0;

    for (0..5) |i| {
        value ^= key1 ^ tweak ^ round_constants[i];
        if (i > 0) value = multiply(shuffle(value));
        value = substitute(value, false);
        tweak = tweakShuffle(tweak);
    }
    value ^= modk0 ^ tweak;
    value = multiply(shuffle(substitute(multiply(shuffle(value)), false)));
    value ^= key1;
    value = inverseShuffle(value);
    value = multiply(substitute(value, true));
    value = inverseShuffle(value) ^ key0 ^ tweak;

    for (0..5) |i| {
        value = substitute(value, true);
        if (i < 4) value = inverseShuffle(multiply(value));
        tweak = tweakInverseShuffle(tweak);
        value ^= round_constants[4 - i] ^ key1 ^ tweak ^ alpha;
    }
    return value ^ modk0;
}

fn cell(value: u64, index: u6) u4 {
    return @truncate(value >> (index * 4));
}

fn put(out: *u64, index: u6, value: u4) void {
    out.* |= @as(u64, value) << (index * 4);
}

fn shuffle(value: u64) u64 {
    const positions = [_]u6{ 13, 6, 11, 0, 7, 12, 1, 10, 8, 3, 14, 5, 2, 9, 4, 15 };
    var out: u64 = 0;
    for (positions, 0..) |position, n| put(&out, @intCast(n), cell(value, position));
    return out;
}

fn inverseShuffle(value: u64) u64 {
    const positions = [_]u6{ 3, 6, 12, 9, 14, 11, 1, 4, 8, 13, 7, 2, 5, 0, 10, 15 };
    var out: u64 = 0;
    for (positions, 0..) |position, n| put(&out, @intCast(n), cell(value, position));
    return out;
}

fn substitute(value: u64, inverse: bool) u64 {
    const forward = [_]u4{ 0xB, 6, 8, 0xF, 0xC, 0, 9, 0xE, 3, 7, 4, 5, 0xD, 2, 1, 0xA };
    const backward = [_]u4{ 5, 0xE, 0xD, 8, 0xA, 0xB, 1, 9, 2, 6, 0xF, 0, 4, 0xC, 7, 3 };
    const table = if (inverse) backward else forward;
    var out: u64 = 0;
    for (0..16) |i| put(&out, @intCast(i), table[cell(value, @intCast(i))]);
    return out;
}

fn rotateCell(value: u4, amount: u2) u4 {
    const other: u2 = if (amount == 1) 3 else 2;
    return (value << amount) | (value >> other);
}

fn multiply(value: u64) u64 {
    var out: u64 = 0;
    for (0..4) |i| {
        const a = cell(value, @intCast(i));
        const b = cell(value, @intCast(i + 4));
        const c = cell(value, @intCast(i + 8));
        const d = cell(value, @intCast(i + 12));
        put(&out, @intCast(i), rotateCell(d, 1) ^ rotateCell(c, 2) ^ rotateCell(b, 1));
        put(&out, @intCast(i + 4), rotateCell(d, 2) ^ rotateCell(c, 1) ^ rotateCell(a, 1));
        put(&out, @intCast(i + 8), rotateCell(d, 1) ^ rotateCell(b, 1) ^ rotateCell(a, 2));
        put(&out, @intCast(i + 12), rotateCell(c, 1) ^ rotateCell(b, 2) ^ rotateCell(a, 1));
    }
    return out;
}

fn tweakRotate(value: u4) u4 {
    return (value >> 1) | (((value ^ (value >> 1)) & 1) << 3);
}

fn tweakInverseRotate(value: u4) u4 {
    return ((value << 1) & 0xF) | ((value & 1) ^ (value >> 3));
}

fn tweakShuffle(value: u64) u64 {
    const positions = [_]u6{ 4, 5, 6, 7, 11, 2, 3, 8, 12, 13, 14, 15, 0, 1, 10, 9 };
    const rotate = [_]bool{ false, false, true, false, true, false, false, true, false, false, false, true, true, false, true, true };
    return tweakPermute(value, positions, rotate, false);
}

fn tweakInverseShuffle(value: u64) u64 {
    const positions = [_]u6{ 12, 13, 5, 6, 0, 1, 2, 3, 7, 15, 14, 4, 8, 9, 10, 11 };
    const rotate = [_]bool{ true, false, false, false, false, false, true, false, true, true, true, true, false, false, false, true };
    return tweakPermute(value, positions, rotate, true);
}

fn tweakPermute(value: u64, positions: [16]u6, rotate: [16]bool, inverse: bool) u64 {
    var out: u64 = 0;
    for (positions, 0..) |position, n| {
        const v = cell(value, position);
        put(&out, @intCast(n), if (!rotate[n]) v else if (inverse) tweakInverseRotate(v) else tweakRotate(v));
    }
    return out;
}
