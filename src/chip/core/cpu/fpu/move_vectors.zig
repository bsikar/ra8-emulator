//! Conformance vectors for VMOV (immediate), worked from VFPExpandImm in
//! the Arm ARM (DDI0553), and for VMSR/VMRS on FPSCR: which bits a write
//! keeps (reserved ones read back as zero) and what VMRS APSR_nzcv copies.
const vector = @import("../conformance/vector.zig");
const case = @import("case.zig");

pub const Imm32 = vector.Vector(case.Imm, case.Result(u32));
pub const Imm64 = vector.Vector(case.Imm, case.Result(u64));
pub const Move = vector.Vector(case.Word, case.Result(u32));

pub const imm_single = [_]Imm32{
    .{ .encoding = "VMOV (immediate)", .name = "1.0", .input = .{ .imm8 = 0x70 }, .expect = .{ .bits = 0x3F80_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "2.0", .input = .{ .imm8 = 0x00 }, .expect = .{ .bits = 0x4000_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "-2.0", .input = .{ .imm8 = 0x80 }, .expect = .{ .bits = 0xC000_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "1.9375", .input = .{ .imm8 = 0x7F }, .expect = .{ .bits = 0x3FF8_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "0.5", .input = .{ .imm8 = 0x60 }, .expect = .{ .bits = 0x3F00_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "16.0", .input = .{ .imm8 = 0x30 }, .expect = .{ .bits = 0x4180_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "7.75", .input = .{ .imm8 = 0x1F }, .expect = .{ .bits = 0x40F8_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "0.2421875", .input = .{ .imm8 = 0x4F }, .expect = .{ .bits = 0x3E78_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "0.125, the smallest", .input = .{ .imm8 = 0x40 }, .expect = .{ .bits = 0x3E00_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "-31.0, the largest magnitude", .input = .{ .imm8 = 0xBF }, .expect = .{ .bits = 0xC1F8_0000 } },
};

pub const imm_double = [_]Imm64{
    .{ .encoding = "VMOV (immediate)", .name = "1.0", .input = .{ .imm8 = 0x70 }, .expect = .{ .bits = 0x3FF0_0000_0000_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "2.0", .input = .{ .imm8 = 0x00 }, .expect = .{ .bits = 0x4000_0000_0000_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "-2.0", .input = .{ .imm8 = 0x80 }, .expect = .{ .bits = 0xC000_0000_0000_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "1.9375", .input = .{ .imm8 = 0x7F }, .expect = .{ .bits = 0x3FFF_0000_0000_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "0.5", .input = .{ .imm8 = 0x60 }, .expect = .{ .bits = 0x3FE0_0000_0000_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "16.0", .input = .{ .imm8 = 0x30 }, .expect = .{ .bits = 0x4030_0000_0000_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "0.125, the smallest", .input = .{ .imm8 = 0x40 }, .expect = .{ .bits = 0x3FC0_0000_0000_0000 } },
    .{ .encoding = "VMOV (immediate)", .name = "-31.0, the largest magnitude", .input = .{ .imm8 = 0xBF }, .expect = .{ .bits = 0xC03F_0000_0000_0000 } },
};

pub const vmsr = [_]Move{
    .{ .encoding = "VMSR", .name = "every bit set keeps only the implemented ones", .input = .{ .a = 0xFFFF_FFFF }, .expect = .{ .bits = 0xFFCF_009F } },
    .{ .encoding = "VMSR", .name = "RMode, FZ and DN", .input = .{ .a = 0x03C0_0000 }, .expect = .{ .bits = 0x03C0_0000 } },
    .{ .encoding = "VMSR", .name = "AHP", .input = .{ .a = 0x0400_0000 }, .expect = .{ .bits = 0x0400_0000 } },
    .{ .encoding = "VMSR", .name = "FZ16", .input = .{ .a = 0x0008_0000 }, .expect = .{ .bits = 0x0008_0000 } },
    .{ .encoding = "VMSR", .name = "LTPSIZE", .input = .{ .a = 0x0007_0000 }, .expect = .{ .bits = 0x0007_0000 } },
    .{ .encoding = "VMSR", .name = "QC and the cumulative flags", .input = .{ .a = 0x0800_009F }, .expect = .{ .bits = 0x0800_009F } },
    .{ .encoding = "VMSR", .name = "bits 5 and 6 are reserved", .input = .{ .a = 0x0000_0060 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VMSR", .name = "bits 8 to 15 are reserved", .input = .{ .a = 0x0000_FF00 }, .expect = .{ .bits = 0x0000_0000 } },
    .{ .encoding = "VMSR", .name = "bits 20 and 21 are reserved", .input = .{ .a = 0x0030_0000 }, .expect = .{ .bits = 0x0000_0000 } },
};

pub const vmrs = [_]Move{
    .{ .encoding = "VMRS", .name = "reads back what VMSR kept", .input = .{ .a = 0xFFFF_FFFF }, .expect = .{ .bits = 0xFFCF_009F } },
    .{ .encoding = "VMRS", .name = "the LTPSIZE default", .input = .{ .a = 0x0004_0000 }, .expect = .{ .bits = 0x0004_0000 } },
};

pub const vmrs_nzcv = [_]Move{
    .{ .encoding = "VMRS", .name = "N and C", .input = .{ .a = 0xA000_0000 }, .expect = .{ .bits = 0xA000_0000 } },
    .{ .encoding = "VMRS", .name = "only the flags reach the APSR", .input = .{ .a = 0x6FCF_009F }, .expect = .{ .bits = 0x6000_0000 } },
    .{ .encoding = "VMRS", .name = "no flags set", .input = .{ .a = 0x0FCF_009F }, .expect = .{ .bits = 0x0000_0000 } },
};

pub const claimed = [_][]const u8{
    "VMOV (immediate)",
    "VMSR",
    "VMRS",
};

pub const covered = vector.encodingsOf(case.Imm, case.Result(u32), &imm_single) ++
    vector.encodingsOf(case.Imm, case.Result(u64), &imm_double) ++
    vector.encodingsOf(case.Word, case.Result(u32), &vmsr) ++
    vector.encodingsOf(case.Word, case.Result(u32), &vmrs) ++
    vector.encodingsOf(case.Word, case.Result(u32), &vmrs_nzcv);
