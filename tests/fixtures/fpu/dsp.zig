//! Helium DSP corpus (RA8EMU-116): the CMSIS-DSP kernel shapes (q15/q31
//! dot product, q15 FIR, q7/q15 add with saturation, q31 scale, f32 dot
//! product, q15 max) written as plain Zig loops so LLVM picks the Helium
//! paths. Sizes come from SRAM at run time; each result goes to
//! SRAM 0x22000100.

const results: [*]volatile u32 = @ptrFromInt(0x2200_0100);
const knob: *volatile u32 = @ptrFromInt(0x2200_0080);
const counts = [_]u32{ 0, 1, 7, 8, 9, 31, 64 };
const qa: *[64]i16 = @ptrFromInt(0x2200_1000);
const qb: *[64]i16 = @ptrFromInt(0x2200_1080);
const qd: *[64]i16 = @ptrFromInt(0x2200_1100);
const la: *[64]i32 = @ptrFromInt(0x2200_1200);
const lb: *[64]i32 = @ptrFromInt(0x2200_1300);
const ba: *[64]i8 = @ptrFromInt(0x2200_1400);
const bb: *[64]i8 = @ptrFromInt(0x2200_1440);
const fa: *[64]f32 = @ptrFromInt(0x2200_1500);
const fb: *[64]f32 = @ptrFromInt(0x2200_1600);
var slot: usize = 0;

fn store(x: u32) void {
    results[slot] = x;
    slot += 1;
}

noinline fn dotQ15(a: [*]const i16, b: [*]const i16, n: u32) u32 {
    var s: i64 = 0;
    for (a[0..n], b[0..n]) |x, y| s += @as(i32, x) * y;
    return @truncate(@as(u64, @bitCast(s >> 6)));
}

noinline fn dotQ31(a: [*]const i32, b: [*]const i32, n: u32) u32 {
    var s: i64 = 0;
    for (a[0..n], b[0..n]) |x, y| s +%= (@as(i64, x) * y) >> 14;
    return @truncate(@as(u64, @bitCast(s >> 16)));
}

noinline fn addQ15(d: [*]i16, a: [*]const i16, b: [*]const i16, n: u32) void {
    for (d[0..n], a[0..n], b[0..n]) |*o, x, y| o.* = x +| y;
}

noinline fn addQ7(d: [*]i8, a: [*]const i8, b: [*]const i8, n: u32) void {
    for (d[0..n], a[0..n], b[0..n]) |*o, x, y| o.* = x +| y;
}

noinline fn scaleQ31(d: [*]i32, n: u32, k: i32) void {
    for (d[0..n]) |*o| o.* = @truncate((@as(i64, o.*) * k) >> 31);
}

noinline fn maxQ15(a: [*]const i16, n: u32) u32 {
    var m: i16 = -32768;
    for (a[0..n]) |x| m = @max(m, x);
    return @bitCast(@as(i32, m));
}

noinline fn firQ15(d: [*]i16, x: [*]const i16, h: [*]const i16, n: u32) void {
    for (0..n) |i| {
        var s: i32 = 0;
        for (0..8) |k| s +%= @as(i32, x[i + k]) * h[k];
        d[i] = @truncate(s >> 15);
    }
}

noinline fn dotF32(a: [*]const f32, b: [*]const f32, n: u32) u32 {
    var s: f32 = 0;
    for (a[0..n], b[0..n]) |x, y| s = @mulAdd(f32, x, y, s);
    return @bitCast(s);
}

noinline fn sumBytes(p: [*]const i8, n: u32) u32 {
    var s: u32 = 0;
    for (p[0..n]) |x| s +%= @bitCast(@as(i32, x));
    return s;
}

noinline fn sumHalves(p: [*]const i16, n: u32) u32 {
    var s: u32 = 0;
    for (p[0..n]) |x| s +%= @bitCast(@as(i32, x));
    return s;
}

noinline fn sumWords(p: [*]const i32, n: u32) u32 {
    var s: u32 = 0;
    for (p[0..n]) |x| s +%= @bitCast(x);
    return s;
}

fn fill() void {
    for (0..64) |i| {
        const v: u32 = @intCast(i);
        qa[i] = @bitCast(@as(u16, @truncate(v *% 0x4E35 +% 0x1234)));
        qb[i] = @bitCast(@as(u16, @truncate(v *% 0x2F1B +% 0x7001)));
        la[i] = @bitCast(v *% 0x9E37_79B9);
        lb[i] = @bitCast(v *% 0x85EB_CA6B +% 0x1357);
        ba[i] = @bitCast(@as(u8, @truncate(v *% 37 +% 100)));
        bb[i] = @bitCast(@as(u8, @truncate(v *% 91 +% 60)));
        fa[i] = @as(f32, @floatFromInt(v)) * 0.25 - 3.0;
        fb[i] = 1.5 - @as(f32, @floatFromInt(v)) * 0.125;
    }
}

export fn main() void {
    for (counts) |c| {
        knob.* = c;
        const n = knob.*;
        fill();
        store(dotQ15(qa, qb, n));
        store(dotQ31(la, lb, n));
        addQ15(qd, qa, qb, n);
        store(sumHalves(qd, n));
        addQ7(ba, ba, bb, n);
        store(sumBytes(ba, n));
        scaleQ31(la, n, 0x5A82_7999);
        store(sumWords(la, n));
        store(maxQ15(qb, n));
        firQ15(qd, qa, qb, if (n > 56) 56 else n);
        store(sumHalves(qd, if (n > 56) 56 else n));
        store(dotF32(fa, fb, n));
    }
    store(0x0F9C_0DE5);
}
