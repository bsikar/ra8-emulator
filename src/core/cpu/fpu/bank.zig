//! The FPv5 extension register file: S0-S31, aliased as D0-D15 with
//! D[n] = S[2n+1]:S[2n] (little-endian pairs), which is all the M-profile
//! single and double precision unit has. The core-register forms of VMOV
//! move raw bits through it: S to or from one core register, two core
//! registers to or from a D register (Rt is the low word) or to or from
//! two consecutive S registers.
pub const Bank = struct {
    s: [32]u32 = @splat(0),

    pub fn readS(self: *const Bank, n: u5) u32 {
        return self.s[n];
    }

    pub fn writeS(self: *Bank, n: u5, value: u32) void {
        self.s[n] = value;
    }

    pub fn readD(self: *const Bank, n: u4) u64 {
        const lo: u5 = @as(u5, n) * 2;
        return @as(u64, self.s[lo + 1]) << 32 | self.s[lo];
    }

    pub fn writeD(self: *Bank, n: u4, value: u64) void {
        const lo: u5 = @as(u5, n) * 2;
        self.s[lo] = @truncate(value);
        self.s[lo + 1] = @truncate(value >> 32);
    }

    /// VMOV Dm, Rt, Rt2: Rt fills the low word.
    pub fn writeCorePair(self: *Bank, n: u4, rt: u32, rt2: u32) void {
        self.writeD(n, @as(u64, rt2) << 32 | rt);
    }

    /// VMOV Rt, Rt2, Dm: the low word, then the high word.
    pub fn readCorePair(self: *const Bank, n: u4) [2]u32 {
        const value = self.readD(n);
        return .{ @truncate(value), @truncate(value >> 32) };
    }

    /// VMOV Sm, Sm1, Rt, Rt2: Sm must not be S31, which has no successor.
    pub fn writeSPair(self: *Bank, m: u5, rt: u32, rt2: u32) void {
        self.s[m] = rt;
        self.s[m + 1] = rt2;
    }
};
