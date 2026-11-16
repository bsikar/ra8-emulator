//! LOB corpus (RA8EMU-232): loops LLVM turns into low-overhead and
//! tail-predicated loops on the Cortex-M85. Trip counts come from SRAM at
//! run time so nothing folds; each result goes to SRAM 0x22000100.

const results: [*]volatile u32 = @ptrFromInt(0x2200_0100);
const knob: *volatile u32 = @ptrFromInt(0x2200_0080);
const counts = [_]u32{ 0, 1, 3, 4, 5, 16, 17, 37, 64 };
// The arrays sit at fixed SRAM addresses past the results so .bss (linked
// at 0x22000000) cannot overlap the words the test reads at 0x22000100.
const words: *[64]u32 = @ptrFromInt(0x2200_1000);
const other: *[64]u32 = @ptrFromInt(0x2200_1100);
const halves: *[64]u16 = @ptrFromInt(0x2200_1200);
const bytes: *[64]u8 = @ptrFromInt(0x2200_1280);
var slot: usize = 0;

fn store(x: u32) void {
    results[slot] = x;
    slot += 1;
}

noinline fn sumWords(p: [*]const u32, n: u32) u32 {
    var s: u32 = 0;
    for (p[0..n]) |x| s +%= x;
    return s;
}

noinline fn sumBytes(p: [*]const u8, n: u32) u32 {
    var s: u32 = 0;
    for (p[0..n]) |x| s +%= x;
    return s;
}

noinline fn addWords(d: [*]u32, a: [*]const u32, b: [*]const u32, n: u32) void {
    for (d[0..n], a[0..n], b[0..n]) |*o, x, y| o.* = x +% y *% 3;
}

noinline fn scaleHalves(d: [*]u16, n: u32, k: u16) void {
    for (d[0..n]) |*o| o.* = o.* *% k +% 7;
}

noinline fn dotHalves(a: [*]const u16, b: [*]const u16, n: u32) u32 {
    var s: u32 = 0;
    for (a[0..n], b[0..n]) |x, y| s +%= @as(u32, x) * y;
    return s;
}

noinline fn hashWords(p: [*]const u32, n: u32) u32 {
    var h: u32 = 0x811C_9DC5;
    for (p[0..n]) |x| h = (h ^ x) *% 0x0100_0193;
    return h;
}

noinline fn fill(n: u32) void {
    for (0..n) |i| {
        const v: u32 = @intCast(i);
        words[i] = v *% 0x9E37_79B9;
        other[i] = v *% 0x85EB_CA6B +% 1;
        halves[i] = @truncate(v *% 0x2545 +% 3);
        bytes[i] = @truncate(v *% 37 +% 11);
    }
}

export fn main() void {
    for (counts) |c| {
        knob.* = c;
        const n = knob.*;
        fill(64);
        store(sumWords(words, n));
        store(sumBytes(bytes, n));
        addWords(other, words, other, n);
        store(sumWords(other, 64));
        scaleHalves(halves, n, 0x0105);
        store(dotHalves(halves, halves, 64));
        store(hashWords(words, n));
    }
    store(0x0F9C_0DE5);
}
