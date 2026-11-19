//! The machines the command line can name (RA8EMU-1342). An unknown name
//! is refused rather than quietly falling back to a default.
const std = @import("std");

const generic = @import("generic.zig");
const Machine = @import("machine.zig").Machine;
const Part = @import("../part/part.zig").Part;
const ra8_cores = @import("../part/cores.zig");

/// The EK-RA8D2's part, and the default: a Cortex-M85 CPU0 and a
/// Cortex-M33 CPU1.
pub const ra8d2: Machine = .{
    .name = "ra8d2",
    .label = "RA8D2",
    .cores = .{ .primary = ra8_cores.cpu0, .second = ra8_cores.cpu1 },
    .part = .ra8d2,
};

/// The RA8P1: the RA8D2's cores and map, with the Ethos-U55.
pub const ra8p1: Machine = .{
    .name = "ra8p1",
    .label = "RA8P1",
    .cores = .{ .primary = ra8_cores.cpu0, .second = ra8_cores.cpu1 },
    .part = .ra8p1,
};

/// Minimal single-core Cortex-M33 with SCS, flash, and SRAM only.
pub const cortex_m33 = generic.cortex_m33;

/// Minimal single-core Cortex-M85 with SCS, flash, and SRAM only.
pub const cortex_m85 = generic.cortex_m85;

pub const all = [_]*const Machine{ &ra8d2, &ra8p1, &cortex_m33, &cortex_m85 };

/// The machine called `name` in `machines`, or null when absent.
pub fn findIn(machines: []const *const Machine, name: []const u8) ?*const Machine {
    for (machines) |machine| {
        if (std.mem.eql(u8, machine.name, name)) return machine;
    }
    return null;
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
