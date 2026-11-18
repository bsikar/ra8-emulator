//! The two cores the RA8D2 and the RA8P1 carry, as machine descriptions
//! (RA8EMU-1342).
//!
//! CPU0 is a Cortex-M85 with the Security Extension and a half, single and
//! double precision FPU; CPU1 a Cortex-M33 with the Security and DSP
//! extensions and a single-precision FPU. Both datasheets, RA8D2
//! R01DS0493EJ0130 and RA8P1 R01DS0439EJ0130 Rev.1.30 section 1.1 Table 1.1
//! p2, say so, and list "Embeds two Systick timers: Secure and Non-secure
//! instance" for each core. Arm's Cortex-M85 Devices Generic
//! User Guide (101928, issue 0101), "System timer, SysTick", says the same
//! for CPU0; a Cortex-M33 has two only with the Security Extension (Arm
//! 100235, issue 0100). With two, SHPR3.PRI_15 and SHCSR.SYSTICKACT are
//! banked (src/chip/periph/scb/bank.zig).
const core = @import("../machine/core.zig");

pub const cpu0 = core.cortexM85(.{ .security = true, .fpu = .double, .systicks = 2 });
pub const cpu1 = core.cortexM33(.{ .security = true, .fpu = .single, .systicks = 2 });
