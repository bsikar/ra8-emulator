//! Which instruction groups a core implements (RA8EMU-233).
//!
//! Models Cortex-M85 (Armv8.1-M + MVE + LOB + PACBTI + DP FPU), Cortex-M55
//! (Armv8.1-M + configurable MVE/FPU/LOB without PACBTI), and Cortex-M33
//! (Armv8.0-M Mainline with DSP and optional FPv5-SP).
const id_regs = @import("../../periph/id_regs.zig");

/// What a decode group needs from the core before it may claim an encoding.
pub const Feature = enum {
    /// Armv8-M Mainline with DSP and the FP extension.
    base,
    /// The Armv8.1-M Mainline additions outside MVE, LOB, and PACBTI:
    /// CSEL and its family, CLRM, VSCCLRM.
    v8_1m,
    /// The M-profile Vector Extension, and the scalar long shifts that come
    /// with it (ASRL, LSLL, LSRL, UQSHLL, ...).
    mve,
    /// The low-overhead loop and branch instructions: WLS, DLS, LE, LCTP.
    lob,
    /// Pointer Authentication and Branch Target Identification (Armv8.1-M
    /// PACBTI extension: Cortex-M85, absent on Cortex-M55 and Cortex-M33).
    pacbti,
};

/// The floating-point unit a core implements.
pub const Fpu = enum {
    none,
    /// FPv5 single precision, as a Cortex-M33 carries it (or half+single when `fp16`).
    single,
    /// FPv5 single and double precision, as a Cortex-M85 or Cortex-M55 carries it.
    double,
};

pub const Profile = struct {
    v8_1m: bool,
    mve: bool,
    lob: bool,
    pacbti: bool = false,
    mve_fp: bool = true,
    fpu: Fpu = .double,
    fp16: bool = true,
    cache: bool = true,
    dwt_comparators: u4 = 8,
    prio_bits: u4 = 4,
    irq_lines: u16 = 96,
    init_vtor: ?u32 = null,

    /// Cortex-M85: Armv8.1-M Mainline with MVE, LOB, PACBTI, and DP FPU.
    pub const m85: Profile = .{
        .v8_1m = true,
        .mve = true,
        .lob = true,
        .pacbti = true,
        .mve_fp = true,
        .fpu = .double,
        .fp16 = true,
        .cache = true,
        .dwt_comparators = 8,
    };
    /// Cortex-M55: Armv8.1-M Mainline with MVE/LOB/FP and no PACBTI.
    pub const m55: Profile = .{
        .v8_1m = true,
        .mve = true,
        .lob = true,
        .pacbti = false,
        .mve_fp = true,
        .fpu = .double,
        .fp16 = true,
        .cache = true,
        .dwt_comparators = 4,
    };
    /// Cortex-M33: Armv8.0-M Mainline, DSP, FPv5-SP.
    pub const m33: Profile = .{
        .v8_1m = false,
        .mve = false,
        .lob = false,
        .pacbti = false,
        .mve_fp = false,
        .fpu = .single,
        .fp16 = false,
        .cache = false,
        .dwt_comparators = 4,
    };

    pub fn has(self: Profile, feature: Feature) bool {
        return switch (feature) {
            .base => true,
            .v8_1m => self.v8_1m,
            .mve => self.mve,
            .lob => self.lob,
            .pacbti => self.pacbti,
        };
    }

    pub fn hasMveFloat(self: Profile) bool {
        return self.mve and self.mve_fp and self.fpu != .none;
    }

    pub fn idBank(self: Profile, security: bool, fpb_code: u5) id_regs.Bank {
        const fpu_kind: id_regs.FpuKind = switch (self.fpu) {
            .none => .none,
            .single => .single,
            .double => .double,
        };
        return id_regs.Bank.fromConfig(.{
            .v8_1m = self.v8_1m,
            .mve = self.mve,
            .mve_fp = self.hasMveFloat(),
            .lob = self.lob,
            .pacbti = self.pacbti,
            .fpu = fpu_kind,
            .fp16 = self.fp16,
            .security = security,
            .halting_debug = self.dwt_comparators > 0 or fpb_code > 0,
            .tcm = self.v8_1m,
            .cache_maint = self.v8_1m and self.cache,
        });
    }

    /// Mask of implemented priority bits in an 8-bit priority byte.
    pub fn prioMask(self: Profile) u8 {
        if (self.prio_bits == 0) return 0;
        if (self.prio_bits >= 8) return 0xFF;
        return @as(u8, 0xFF) << @intCast(8 - @as(u5, self.prio_bits));
    }
};
