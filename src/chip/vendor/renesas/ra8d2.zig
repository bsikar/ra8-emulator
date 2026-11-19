//! Renesas RA8D2 dual-core MCU definition (Cortex-M85 primary, Cortex-M33 secondary).
const cores = @import("../../core/part/cores.zig");
const Machine = @import("../../core/machine/machine.zig").Machine;
const memory = @import("../../core/machine/memory.zig");

pub const machine: Machine = .{
    .name = "ra8d2",
    .label = "RA8D2",
    .cores = .{ .primary = cores.cpu0, .second = cores.cpu1 },
    .memory = &memory.ra8,
    .part = .ra8d2,
};
