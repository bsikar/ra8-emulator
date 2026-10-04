//! FPU mode corpus (RA8EMU-143): non-default FPSCR rounding modes, FZ, DN,
//! scalar fixed-point conversion and f16 arithmetic on the Cortex-M85.
//! Every operation stores its result and `FPSCR & 0x03C0009F` to SRAM.

const results: [*]volatile u32 = @ptrFromInt(0x2200_0100);
const fpscr_mask: u32 = 0x03C0_009F;
const modes = [_]u32{ 0, 0x0040_0000, 0x0080_0000, 0x00C0_0000 }; // RN, RP, RM, RZ
var slot: usize = 0;

fn store(x: u32) void {
    results[slot] = x;
    slot += 1;
}

fn setMode(x: u32) void {
    asm volatile ("vmsr fpscr, %[x]"
        :
        : [x] "r" (x),
        : "memory"
    );
}

fn flags() void {
    store(asm volatile ("vmrs %[x], fpscr"
        : [x] "=r" (-> u32),
        :
        : "memory"
    ) & fpscr_mask);
}

fn binary(comptime insn: []const u8, mode: u32, a: u32, b: u32) void {
    setMode(mode);
    store(asm volatile ("vmov s0, %[a]\nvmov s1, %[b]\n" ++ insn ++ "\nvmov %[r], s0"
        : [r] "=r" (-> u32),
        : [a] "r" (a),
          [b] "r" (b),
        : "s0", "s1", "memory"
    ));
    flags();
}

fn unary(comptime insn: []const u8, mode: u32, x: u32, mask: u32) void {
    setMode(mode);
    store(asm volatile ("vmov s0, %[x]\n" ++ insn ++ "\nvmov %[r], s0"
        : [r] "=r" (-> u32),
        : [x] "r" (x),
        : "s0", "memory"
    ) & mask);
    flags();
}

fn rounding(mode: u32) void {
    binary("vadd.f32 s0, s0, s1", mode, 0x3F80_0000, 0x3380_0000);
    binary("vadd.f32 s0, s0, s1", mode, 0xBF80_0000, 0xB380_0000);
    binary("vdiv.f32 s0, s0, s1", mode, 0x3F80_0000, 0x4040_0000);
    binary("vdiv.f32 s0, s0, s1", mode, 0xBF80_0000, 0x4040_0000);
    unary("vcvtr.s32.f32 s0, s0", mode, 0x4020_0000, 0xFFFF_FFFF);
    unary("vcvtr.s32.f32 s0, s0", mode, 0xC020_0000, 0xFFFF_FFFF);
}

fn fixed() void {
    unary("vcvt.s32.f32 s0, s0, #16", 0, 0x3FC0_0000, 0xFFFF_FFFF);
    unary("vcvt.s32.f32 s0, s0, #16", 0, 0xBFA0_0000, 0xFFFF_FFFF);
    unary("vcvt.f32.s32 s0, s0, #16", 0, 0x0001_8000, 0xFFFF_FFFF);
    unary("vcvt.f32.s32 s0, s0, #16", 0, 0xFFFE_C000, 0xFFFF_FFFF);
    unary("vcvt.u16.f32 s0, s0, #8", 0, 0x3FC0_0000, 0xFFFF_FFFF);
    unary("vcvt.s16.f32 s0, s0, #8", 0, 0xBF80_0000, 0xFFFF_FFFF);
}

fn modesAndHalf() void {
    binary("vadd.f32 s0, s0, s1", 0x0100_0000, 0x0000_0001, 0); // FZ input
    binary("vadd.f32 s0, s0, s1", 0x0200_0000, 0x7FC0_1234, 0x3F80_0000); // DN qNaN
    binary("vadd.f32 s0, s0, s1", 0x0200_0000, 0x7F80_0001, 0x3F80_0000); // DN sNaN
    binary("vadd.f16 s0, s0, s1", 0, 0x3C00, 0x4000);
    binary("vmul.f16 s0, s0, s1", 0, 0x5CB0, 0x5CB0);
    binary("vdiv.f16 s0, s0, s1", 0, 0x3C00, 0x4200);
    unary("vsqrt.f16 s0, s0", 0, 0x4400, 0xFFFF);
    setMode(0);
    store(asm volatile ("vmov s0, %[d]\nvmov s1, %[n]\nvmov s2, %[m]\nvfma.f16 s0, s1, s2\nvmov %[r], s0"
        : [r] "=r" (-> u32),
        : [d] "r" (@as(u32, 0x3C00)),
          [n] "r" (@as(u32, 0x4000)),
          [m] "r" (@as(u32, 0x4200)),
        : "s0", "s1", "s2", "memory"
    ) & 0xFFFF);
    flags();
    binary("vadd.f16 s0, s0, s1", 0x0008_0000, 0x0001, 0); // FZ16 input
}

export fn main() void {
    slot = 0;
    for (modes) |mode| rounding(mode);
    fixed();
    modesAndHalf();
    store(0x0F9C_0DE5);
}
