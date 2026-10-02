//! The shape of an FPU conformance vector: the operands as encoded, the FPSCR
//! controls that change the answer (rounding mode, FZ, DN), and what the
//! pseudocode produces, the result bits and the cumulative flags raised.
const fpscr_mod = @import("fpscr.zig");
const Fpscr = fpscr_mod.Fpscr;
const RMode = fpscr_mod.RMode;

pub fn Binary(comptime B: type) type {
    return struct {
        a: B,
        b: B,
        mode: RMode = .nearest,
        fz: u1 = 0,
        dn: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .rmode = self.mode, .fz = self.fz, .dn = self.dn };
        }
    };
}

/// Three operands, as the accumulating forms read them: d is the
/// accumulator, n and m the factors.
pub fn Ternary(comptime B: type) type {
    return struct {
        d: B,
        n: B,
        m: B,
        mode: RMode = .nearest,
        fz: u1 = 0,
        dn: u1 = 0,

        pub fn fpscr(self: @This()) Fpscr {
            return .{ .rmode = self.mode, .fz = self.fz, .dn = self.dn };
        }
    };
}

pub fn Result(comptime B: type) type {
    return struct { bits: B, flags: u32 = 0 };
}

/// The cumulative flags FPSCR holds after an operation, as the low byte
/// VMRS would show.
pub fn flagsOf(fpscr: Fpscr) u32 {
    return fpscr.bits() & fpscr_mod.mask.cumulative;
}

pub const flag = struct {
    pub const ioc: u32 = 1 << 0;
    pub const dzc: u32 = 1 << 1;
    pub const ofc: u32 = 1 << 2;
    pub const ufc: u32 = 1 << 3;
    pub const ixc: u32 = 1 << 4;
    pub const idc: u32 = 1 << 7;
};
