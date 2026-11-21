//! The machines the command line can name (RA8EMU-1342). An unknown name
//! is refused rather than quietly falling back to a default.
const std = @import("std");

const generic = @import("generic.zig");
const hx6538_machine = @import("../../vendor/himax/hx6538/machine.zig").machine;
const Machine = @import("machine.zig").Machine;
const Part = @import("../part/part.zig").Part;
const renesas = @import("../../vendor/renesas/renesas.zig");

/// The EK-RA8D2's part, and the default: a Cortex-M85 CPU0 and a
/// Cortex-M33 CPU1.
pub const ra8d2 = renesas.ra8d2.machine;

/// The RA8P1: the RA8D2's cores and map, with the Ethos-U55.
pub const ra8p1 = renesas.ra8p1.machine;

/// Minimal single-core Cortex-M33 with SCS, flash, and SRAM only.
pub const cortex_m33 = generic.cortex_m33;

/// Minimal single-core Cortex-M55 with SCS, flash, and SRAM only.
pub const cortex_m55 = generic.cortex_m55;

/// Minimal single-core Cortex-M85 with SCS, flash, and SRAM only.
pub const cortex_m85 = generic.cortex_m85;

/// Single-core Cortex-M85 RA8E1 MCU machine profile.
pub const ra8e1 = renesas.ra8e1.machine;

/// Renesas RA4T1 (R7FA4T1BB3CFM, sole primary Cortex-M33 r0p4, alias `fpb-ra4t1`).
pub const ra4t1 = renesas.ra4t1.machine;

/// Himax HX6538 / Seeed Grove Vision AI V2 dual-Cortex-M55 machine.
pub const hx6538 = hx6538_machine;

pub const all = [_]*const Machine{ &ra8d2, &ra8p1, &ra8e1, &ra4t1, &hx6538, &cortex_m33, &cortex_m55, &cortex_m85 };

/// The machine called `name` (canonical name or alias) in `machines`, or null
/// when absent.
pub fn findIn(machines: []const *const Machine, name: []const u8) ?*const Machine {
    for (machines) |machine| {
        if (matches(machine, name)) return machine;
    }
    return null;
}

fn matches(machine: *const Machine, name: []const u8) bool {
    if (std.mem.eql(u8, machine.name, name)) return true;
    for (machine.aliases) |alias| {
        if (std.mem.eql(u8, alias, name)) return true;
    }
    return false;
}

/// The machine called `name`, or null for one this emulator does not model.
pub fn find(name: []const u8) ?*const Machine {
    return findIn(&all, name);
}

/// The shipped dual-core machine for `which`.
pub fn ofPart(which: Part) *const Machine {
    return switch (which) {
        .ra8d2 => &ra8d2,
        .ra8p1 => &ra8p1,
    };
}
