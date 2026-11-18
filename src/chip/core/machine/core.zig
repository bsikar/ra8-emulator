//! One core a machine carries, apart from the slot it sits in (RA8EMU-1342).
//!
//! A slot (CPU0, CPU1) says where a core sits in a machine; this says what
//! the core is: the instruction groups it decodes, the CPUID it answers
//! with, whether it has the Armv8-M Security Extension, which FPU and MVE
//! it carries and how many SysTick timers it has. The interpreter, the CPUID
//! window and the debug units read these off the core, never off the slot,
//! so slot 0 can hold a Cortex-M33 as readily as a Cortex-M85.
const cpuid = @import("../../periph/cpuid.zig");
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
};

/// A Cortex-M85: Armv8.1-M Mainline with the low-overhead branches and
/// optional Helium (MVE), part number 0xD23.
pub fn cortexM85(options: M85Options) Core {
    const decodes: profile.Profile = .{
        .v8_1m = true,
        .mve = options.mve,
        .lob = true,
        .fpu = options.fpu,
        .prio_bits = options.scs.prio_bits,
        .irq_lines = options.scs.irq_lines,
        .init_vtor = options.scs.init_vtor,
    };
    return .{
        .name = "Cortex-M85",
        .profile = decodes,
        .cpuid = cpuid.wordAt(cpuid.partno.cortex_m85, options.revision),
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
    const decodes: profile.Profile = .{
        .v8_1m = false,
        .mve = false,
        .lob = false,
        .fpu = options.fpu,
        .prio_bits = options.scs.prio_bits,
        .irq_lines = options.scs.irq_lines,
        .init_vtor = options.scs.init_vtor,
    };
    return .{
        .name = "Cortex-M33",
        .profile = decodes,
        .cpuid = cpuid.wordAt(cpuid.partno.cortex_m33, options.revision),
        .security = options.security,
        .fpu = options.fpu,
        .mve = false,
        .systicks = options.systicks,
        .scs = options.scs,
    };
}
