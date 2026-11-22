//! One core a machine carries, apart from the slot it sits in (RA8EMU-1342).
//!
//! A slot (CPU0, CPU1) says where a core sits in a machine; this says what
//! the core is: the instruction groups it decodes, the CPUID it answers
//! with, whether it has the Armv8-M Security Extension, which FPU and MVE
//! it carries and how many SysTick timers it has. The interpreter, the CPUID
//! window and the debug units read these off the core, never off the slot,
//! so slot 0 can hold a Cortex-M33 as readily as a Cortex-M85.
const cpuid = @import("../../periph/cpuid.zig");
const id_regs = @import("../../periph/id_regs.zig");
const profile = @import("../cpu/profile.zig");
pub const scs = @import("scs.zig");

/// The floating-point unit a core carries; the decoder refuses encodings
/// outside the configured precision.
pub const Fpu = profile.Fpu;

/// What an MCU fixes for a Cortex-M85 when it builds it.
pub const M85Options = struct {
    security: bool,
    fpu: Fpu,
    mve: bool = true,
    /// Zero to two. A core with the Security Extension that implements
    /// SysTick has a Secure and a Non-secure one.
    systicks: u2,
    revision: cpuid.Revision = .{},
    scs: scs.ScsConfig = .{},
};

/// What a board/chip fixes for a Cortex-M55 when it builds it.
/// Default revision is r1p1 (Arm TRM 101051_0101_02_en and HX6538 DS);
/// override `revision` (e.g. r0p1 for CMSIS headers) or FP/MVE/SCS options
/// per integration.
pub const M55Options = struct {
    security: bool,
    fpu: Fpu,
    fp16: ?bool = null,
    mve: bool = true,
    mve_fp: ?bool = null,
    lob: bool = true,
    cache: bool = true,
    systicks: u2,
    revision: cpuid.Revision = .{ .variant = 1, .patch = 1 },
    scs: scs.ScsConfig = .{},
};

/// What an MCU fixes for a Cortex-M33 when it builds it.
pub const M33Options = struct {
    security: bool,
    fpu: Fpu,
    /// Zero to two. A core with the Security Extension that implements
    /// SysTick has a Secure and a Non-secure one.
    systicks: u2,
    revision: cpuid.Revision = .{},
    scs: scs.ScsConfig = .{},
};

pub const Core = struct {
    /// The processor, as a report prints it.
    name: []const u8,
    /// The instruction groups the core decodes.
    profile: profile.Profile,
    /// The word CPUID answers with (src/chip/periph/cpuid.zig).
    cpuid: u32,
    /// The Armv8-M Security Extension.
    security: bool,
    fpu: Fpu,
    mve: bool,
    systicks: u2,
    scs: scs.ScsConfig = .{},

    pub fn has(self: Core, feature: profile.Feature) bool {
        return self.profile.has(feature);
    }

    pub fn hasFpu(self: Core) bool {
        return self.fpu != .none;
    }

    pub fn hasPacBti(self: Core) bool {
        return self.profile.pacbti;
    }

    pub fn dwtComparators(self: Core) u4 {
        return self.scs.effectiveDwtFor(self.cpuid);
    }

    pub fn idBank(self: Core) id_regs.Bank {
        return self.profile.idBank(self.security, self.scs.fpb_code);
    }
};

/// A Cortex-M85: Armv8.1-M Mainline with the low-overhead branches, PACBTI,
/// and optional Helium (MVE), part number 0xD23.
pub fn cortexM85(options: M85Options) Core {
    const cpuid_word = cpuid.wordAt(cpuid.partno.cortex_m85, options.revision);
    const has_fpu = options.fpu != .none;
    const decodes: profile.Profile = .{
        .v8_1m = true,
        .mve = options.mve,
        .mve_fp = options.mve and has_fpu,
        .lob = true,
        .pacbti = true,
        .fpu = options.fpu,
        .fp16 = has_fpu,
        .cache = true,
        .dwt_comparators = options.scs.effectiveDwtFor(cpuid_word),
        .prio_bits = options.scs.prio_bits,
        .irq_lines = options.scs.irq_lines,
        .init_vtor = options.scs.init_vtor,
    };
    return .{
        .name = "Cortex-M85",
        .profile = decodes,
        .cpuid = cpuid_word,
        .security = options.security,
        .fpu = options.fpu,
        .mve = options.mve,
        .systicks = options.systicks,
        .scs = options.scs,
    };
}

/// A Cortex-M55: Armv8.1-M Mainline with configurable Helium (MVE), LOB,
/// and floating-point precision, without PACBTI, part number 0xD22.
pub fn cortexM55(options: M55Options) Core {
    const cpuid_word = cpuid.wordAt(cpuid.partno.cortex_m55, options.revision);
    const has_fpu = options.fpu != .none;
    const fp16 = options.fp16 orelse has_fpu;
    const mve_fp = options.mve_fp orelse (options.mve and has_fpu);
    const decodes: profile.Profile = .{
        .v8_1m = true,
        .mve = options.mve,
        .mve_fp = options.mve and has_fpu and mve_fp,
        .lob = options.lob,
        .pacbti = false,
        .fpu = options.fpu,
        .fp16 = has_fpu and fp16,
        .cache = options.cache,
        .dwt_comparators = options.scs.effectiveDwtFor(cpuid_word),
        .prio_bits = options.scs.prio_bits,
        .irq_lines = options.scs.irq_lines,
        .init_vtor = options.scs.init_vtor,
    };
    return .{
        .name = "Cortex-M55",
        .profile = decodes,
        .cpuid = cpuid_word,
        .security = options.security,
        .fpu = options.fpu,
        .mve = options.mve,
        .systicks = options.systicks,
        .scs = options.scs,
    };
}

/// A Cortex-M33: Armv8.0-M Mainline with DSP, part number 0xD21. An
/// Armv8.1-M encoding is UNDEFINED on it.
pub fn cortexM33(options: M33Options) Core {
    const cpuid_word = cpuid.wordAt(cpuid.partno.cortex_m33, options.revision);
    const decodes: profile.Profile = .{
        .v8_1m = false,
        .mve = false,
        .mve_fp = false,
        .lob = false,
        .pacbti = false,
        .fpu = options.fpu,
        .fp16 = false,
        .cache = false,
        .dwt_comparators = options.scs.effectiveDwtFor(cpuid_word),
        .prio_bits = options.scs.prio_bits,
        .irq_lines = options.scs.irq_lines,
        .init_vtor = options.scs.init_vtor,
    };
    return .{
        .name = "Cortex-M33",
        .profile = decodes,
        .cpuid = cpuid_word,
        .security = options.security,
        .fpu = options.fpu,
        .mve = false,
        .systicks = options.systicks,
        .scs = options.scs,
    };
}
