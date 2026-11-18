//! Which instruction groups a core implements (RA8EMU-233).
//!
//! One Zig core, two configurations. CPU0 is a Cortex-M85: Armv8.1-M with
//! MVE and the low-overhead branches. CPU1 is a Cortex-M33: Armv8.0-M
//! Mainline with DSP and FPv5-SP only, so an Armv8.1-M encoding there is
//! UNDEFINED and takes UsageFault UNDEFINSTR, as it would on silicon.
//! src/chip/core/part/part.zig picks the profile for each CPU.

/// What a decode group needs from the core before it may claim an encoding.
pub const Feature = enum {
    /// Armv8-M Mainline with DSP and the FP extension: both cores.
    base,
    /// The Armv8.1-M Mainline additions outside MVE and LOB: CSEL and its
    /// family, CLRM, VSCCLRM.
    v8_1m,
    /// The M-profile Vector Extension, and the scalar long shifts that come
    /// with it (ASRL, LSLL, LSRL, UQSHLL, ...).
    mve,
    /// The low-overhead loop and branch instructions: WLS, DLS, LE, LCTP.
    lob,
};

/// The floating-point unit a core implements.
pub const Fpu = enum {
    none,
    /// FPv5 single precision, as a Cortex-M33 carries it.
    single,
    /// FPv5 single and double precision, as a Cortex-M85 carries it.
    double,
};

pub const Profile = struct {
    v8_1m: bool,
    mve: bool,
    lob: bool,
    fpu: Fpu = .double,
    prio_bits: u4 = 4,
    irq_lines: u16 = 96,
    init_vtor: ?u32 = null,

    /// Cortex-M85: everything the decode table has.
    pub const m85: Profile = .{ .v8_1m = true, .mve = true, .lob = true, .fpu = .double };
    /// Cortex-M33: Armv8.0-M Mainline, DSP, FPv5-SP.
    pub const m33: Profile = .{ .v8_1m = false, .mve = false, .lob = false, .fpu = .single };

    pub fn has(self: Profile, feature: Feature) bool {
        return switch (feature) {
            .base => true,
            .v8_1m => self.v8_1m,
            .mve => self.mve,
            .lob => self.lob,
        };
    }

    /// Mask of implemented priority bits in an 8-bit priority byte.
    pub fn prioMask(self: Profile) u8 {
        if (self.prio_bits == 0) return 0;
        if (self.prio_bits >= 8) return 0xFF;
        return @as(u8, 0xFF) << @intCast(8 - @as(u5, self.prio_bits));
    }
};
