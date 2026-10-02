//! Which part a run models.
//!
//! The RA8P1 and the RA8D2 share a register map and a memory map, so one set
//! of peripheral models serves both and an RA8P1-linked ELF boots exactly as
//! an RA8D2 one does. The one difference is that the RA8P1 carries an Arm
//! Ethos-U55 micro-NPU and the RA8D2 does not, so the choice of part decides
//! whether the NPU window answers at all. Everything else on the board is
//! identical, which is why this is an enum; the memory geometry, cited per
//! part, is in src/core/part_map.zig.
const std = @import("std");

pub const map = @import("part_map.zig");
pub const clock = @import("part_clock.zig");

/// SysTick timers on CPU0, the Cortex-M85 both parts carry: two, one Secure
/// and one Non-secure. Arm's Cortex-M85 Devices Generic User Guide (101928,
/// issue 0101), "System timer, SysTick": "There are two 24-bit system
/// timers, a Non-secure SysTick timer and a Secure SysTick timer." With two,
/// SHPR3.PRI_15 and SHCSR.SYSTICKACT are banked (src/periph/scb_bank.zig).
/// CPU1's Cortex-M33 has two only when it carries the Security Extension
/// (Arm 100235, issue 0100); that is not pinned for the RA8P1's CPU1 yet.
pub const cpu0_systicks: u2 = 2;

pub const Part = enum {
    ra8d2,
    ra8p1,

    /// The part named on the command line, or null for a name this emulator
    /// does not model. Nothing is guessed: an unknown name is refused rather
    /// than quietly falling back to the default part.
    pub fn parse(text: []const u8) ?Part {
        if (std.mem.eql(u8, text, "ra8d2")) return .ra8d2;
        if (std.mem.eql(u8, text, "ra8p1")) return .ra8p1;
        return null;
    }

    pub fn label(self: Part) []const u8 {
        return switch (self) {
            .ra8d2 => "RA8D2",
            .ra8p1 => "RA8P1",
        };
    }

    /// Whether this part has the Ethos-U55 NPU behind 0x4014_0000.
    pub fn hasNpu(self: Part) bool {
        return self == .ra8p1;
    }
};
