//! Renesas RA8P1 dual-core MCU definition (RA8D2 cores and memory map plus Ethos-U55 NPU).
const cores = @import("../../core/part/cores.zig");
const Machine = @import("../../core/machine/machine.zig").Machine;
const memory = @import("../../core/machine/memory.zig");

pub const machine: Machine = .{
    .name = "ra8p1",
    .label = "RA8P1",
    .cores = .{ .primary = cores.cpu0, .second = cores.cpu1 },
    .memory = &memory.ra8,
    .part = .ra8p1,
};
