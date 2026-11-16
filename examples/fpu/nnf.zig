//! TFLM / CMSIS-NN float corpus (RA8EMU-321): the float kernel shapes
//! (fully connected, ReLU, element-wise add and mul, max pool, dequantize
//! and requantize, F16 dot and F32 to F16 narrowing, softmax max and
//! normalise) written as plain Zig loops so LLVM picks the Helium float
//! paths. Sizes come from SRAM at run time; each result goes to SRAM
//! 0x22000100.

const results: [*]volatile u32 = @ptrFromInt(0x2200_0100);
const knob: *volatile u32 = @ptrFromInt(0x2200_0080);
const counts = [_]u32{ 0, 1, 5, 8, 13, 32 };
const fa: *[64]f32 = @ptrFromInt(0x2200_1000);
const fb: *[64]f32 = @ptrFromInt(0x2200_1100);
const fd: *[64]f32 = @ptrFromInt(0x2200_1200);
const ha: *[64]f16 = @ptrFromInt(0x2200_1300);
const hb: *[64]f16 = @ptrFromInt(0x2200_1380);
const qi: *[64]i32 = @ptrFromInt(0x2200_1400);
const qb: *[64]i8 = @ptrFromInt(0x2200_1500);
var slot: usize = 0;

fn store(x: u32) void {
    results[slot] = x;
    slot += 1;
}

fn bits(x: f32) u32 {
    return @bitCast(x);
}

noinline fn fullyConnected(d: [*]f32, x: [*]const f32, w: [*]const f32, n: u32) void {
    for (0..4) |row| {
        var s: f32 = 0.5;
        for (0..n) |i| s = @mulAdd(f32, x[i], w[row * 16 + i % 16], s);
        d[row] = s;
    }
}

noinline fn relu(d: [*]f32, n: u32) void {
    for (d[0..n]) |*o| o.* = @max(o.*, 0.0);
}

noinline fn addMul(d: [*]f32, a: [*]const f32, b: [*]const f32, n: u32) void {
    for (d[0..n], a[0..n], b[0..n]) |*o, x, y| o.* = (x + y) * 0.75 - x * y;
}

noinline fn maxF32(a: [*]const f32, n: u32) f32 {
    var m: f32 = -1.0e30;
    for (a[0..n]) |x| m = @max(m, x);
    return m;
}

noinline fn dequant(d: [*]f32, q: [*]const i8, n: u32) void {
    for (d[0..n], q[0..n]) |*o, x| o.* = @as(f32, @floatFromInt(@as(i32, x) - 3)) * 0.0703125;
}

noinline fn requant(d: [*]i32, a: [*]const f32, n: u32) void {
    for (d[0..n], a[0..n]) |*o, x| o.* = @intFromFloat(@round(x * 16.0));
}

noinline fn dotF16(a: [*]const f16, b: [*]const f16, n: u32) u32 {
    var s: f16 = 0;
    for (a[0..n], b[0..n]) |x, y| s = @mulAdd(f16, x, y, s);
    return @as(u16, @bitCast(s));
}

noinline fn narrow(d: [*]f16, a: [*]const f32, n: u32) void {
    for (d[0..n], a[0..n]) |*o, x| o.* = @floatCast(x);
}

noinline fn scaleBy(d: [*]f32, n: u32, k: f32) void {
    for (d[0..n]) |*o| o.* = @abs(o.*) * k;
}

noinline fn sumBits(p: [*]const u32, n: u32) u32 {
    var s: u32 = 0;
    for (p[0..n]) |x| s = (s ^ x) *% 0x0100_0193;
    return s;
}

fn fill() void {
    for (0..64) |i| {
        const v: f32 = @floatFromInt(i);
        fa[i] = v * 0.375 - 5.0;
        fb[i] = 2.25 - v * 0.1875;
        ha[i] = @floatCast(v * 0.125 - 1.5);
        hb[i] = @floatCast(0.75 - v * 0.0625);
        qb[i] = @bitCast(@as(u8, @truncate(@as(u32, @intCast(i)) *% 29 +% 7)));
    }
}

export fn main() void {
    for (counts) |c| {
        knob.* = c;
        const n = knob.*;
        fill();
        fullyConnected(fd, fa, fb, n);
        store(sumBits(@ptrCast(fd), 4));
        addMul(fd, fa, fb, n);
        relu(fd, n);
        store(sumBits(@ptrCast(fd), n));
        store(bits(maxF32(fa, n)));
        dequant(fd, qb, n);
        store(sumBits(@ptrCast(fd), n));
        requant(qi, fa, n);
        store(sumBits(@ptrCast(qi), n));
        store(dotF16(ha, hb, n));
        narrow(@ptrCast(hb), fb, n);
        store(dotF16(ha, hb, n));
        scaleBy(fb, n, 1.0 / 3.0);
        store(sumBits(@ptrCast(fb), n));
    }
    store(0x0F9C_0DE5);
}
