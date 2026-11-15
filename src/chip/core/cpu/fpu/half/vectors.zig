//! Conformance vectors for VCVTB and VCVTT, worked from FPConvert in the
//! Arm ARM (DDI0553). They cover both lanes (the other half kept), the
//! half range edges, overflow per rounding mode, denormals and ties, NaN
//! payloads, DN, FZ on the wide side only, and the alternative half format:
//! exponent 31 as an ordinary binade, saturation and NaNs with IOC alone.
const defs = @import("types.zig");

const f = defs.f;

const case = defs.case;
const vector = defs.vector;
pub const ToHalf32 = defs.ToHalf32;
pub const ToHalf64 = defs.ToHalf64;
pub const FromHalf32 = defs.FromHalf32;
pub const FromHalf64 = defs.FromHalf64;

const from_single_01 = @import("from_single_01.zig");
const from_single_02 = @import("from_single_02.zig");

pub const from_single = from_single_01.values ++
    from_single_02.values;

pub const from_double = [_]ToHalf64{
    .{
        .encoding = "VCVTB",
        .name = "1.0",
        .input = .{ .a = 0x3FF0_0000_0000_0000 },
        .expect = .{ .bits = 0x0000_3C00 },
    },
    .{
        .encoding = "VCVTT",
        .name = "65536 overflows into the top half",
        .input = .{ .a = 0x40F0_0000_0000_0000, .top = true },
        .expect = .{ .bits = 0x7C00_0000, .flags = f.ofc | f.ixc },
    },
    .{
        .encoding = "VCVTB",
        .name = "just above a tie rounds up",
        .input = .{ .a = 0x3FF0_0200_0001_0000 },
        .expect = .{ .bits = 0x0000_3C01, .flags = f.ixc },
    },
    .{
        .encoding = "VCVTB",
        .name = "AHP: 65536",
        .input = .{ .a = 0x40F0_0000_0000_0000, .ahp = 1 },
        .expect = .{ .bits = 0x0000_7C00 },
    },
    .{
        .encoding = "VCVTT",
        .name = "an sNaN is quieted and signals",
        .input = .{ .a = 0x7FF0_0000_0000_0001, .top = true, .d = 0xFFFF_5555 },
        .expect = .{ .bits = 0x7E00_5555, .flags = f.ioc },
    },
};

const to_single_01 = @import("to_single_01.zig");

pub const to_single = to_single_01.values;

pub const to_double = [_]FromHalf64{
    .{
        .encoding = "VCVTB",
        .name = "1.0",
        .input = .{ .a = 0x0000_3C00 },
        .expect = .{ .bits = 0x3FF0_0000_0000_0000 },
    },
    .{
        .encoding = "VCVTT",
        .name = "65504 from the top half",
        .input = .{ .a = 0x7BFF_0000, .top = true },
        .expect = .{ .bits = 0x40EF_FC00_0000_0000 },
    },
    .{
        .encoding = "VCVTB",
        .name = "-2^-24",
        .input = .{ .a = 0x0000_8001 },
        .expect = .{ .bits = 0xBE70_0000_0000_0000 },
    },
    .{
        .encoding = "VCVTB",
        .name = "a quiet NaN widens its payload",
        .input = .{ .a = 0x0000_7E09 },
        .expect = .{ .bits = 0x7FF8_2400_0000_0000 },
    },
    .{
        .encoding = "VCVTT",
        .name = "AHP: -65536",
        .input = .{ .a = 0xFC00_0000, .top = true, .ahp = 1 },
        .expect = .{ .bits = 0xC0F0_0000_0000_0000 },
    },
};

pub const claimed = [_][]const u8{
    "VCVTB",
    "VCVTT",
};

pub const covered = vector.encodingsOf(case.Halves(u32), case.Result(u32), &from_single) ++
    vector.encodingsOf(case.Halves(u64), case.Result(u32), &from_double) ++
    vector.encodingsOf(case.Halves(u32), case.Result(u32), &to_single) ++
    vector.encodingsOf(case.Halves(u32), case.Result(u64), &to_double);
