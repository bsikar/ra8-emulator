//! Conformance vectors for VCVT and VCVTR between floating point and 32-bit
//! integers, worked from FPToFixed and FixedToFP in the Arm ARM (DDI0553)
//! with fbits 0. They cover truncation and each rounding mode, ties,
//! saturation at both ends (IOC, not IXC), negative values into an
//! unsigned result, infinities, NaNs, denormals with and without FZ, and
//! integers that need rounding to fit a float.
const defs = @import("int_types.zig");

const case = defs.case;
const vector = defs.vector;
pub const Single = defs.Single;
pub const Double = defs.Double;
pub const ToDouble = defs.ToDouble;

const from_single_01 = @import("int_from_single_01.zig");
const from_single_02 = @import("int_from_single_02.zig");

pub const from_single = from_single_01.values ++
    from_single_02.values;

const from_double_01 = @import("int_from_double_01.zig");

pub const from_double = from_double_01.values;

const to_single_01 = @import("int_to_single_01.zig");

pub const to_single = to_single_01.values;

pub const to_double = [_]ToDouble{
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "INT_MIN",
        .input = .{ .a = 0x8000_0000 },
        .expect = .{ .bits = 0xC1E0_0000_0000_0000 },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "INT_MAX is exact",
        .input = .{ .a = 0x7FFF_FFFF },
        .expect = .{ .bits = 0x41DF_FFFF_FFC0_0000 },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "UINT_MAX is exact",
        .input = .{ .a = 0xFFFF_FFFF, .unsigned = true },
        .expect = .{ .bits = 0x41EF_FFFF_FFE0_0000 },
    },
    .{
        .encoding = "VCVT (integer to floating-point)",
        .name = "0 is +0",
        .input = .{ .a = 0, .unsigned = true },
        .expect = .{ .bits = 0 },
    },
};

pub const claimed = [_][]const u8{
    "VCVT (between floating-point and integer)",
    "VCVTR",
    "VCVT (integer to floating-point)",
};

pub const covered = vector.encodingsOf(case.Fixed(u32), case.Result(u32), &from_single) ++
    vector.encodingsOf(case.Fixed(u64), case.Result(u32), &from_double) ++
    vector.encodingsOf(case.Fixed(u32), case.Result(u32), &to_single) ++
    vector.encodingsOf(case.Fixed(u32), case.Result(u64), &to_double);
