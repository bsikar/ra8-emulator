//! Reset guest interrupt state at reboot, after the reset tick's pends.
const alias = @import("../../../periph/scs_alias.zig");
const bus = @import("../bus.zig");
const memmap = @import("../../memmap.zig");
const nvic = @import("../../../periph/nvic/nvic.zig");
const scs_mod = @import("../../machine/scs.zig");

/// Standalone CPU buses may omit SCS. Every mapped bank is reset; failures
/// other than an absent bank remain errors, rather than a partial success.
pub fn clear(memory: bus.Bus) bus.Error!void {
    return clearFor(memory, nvic.irq_lines, null);
}

pub fn clearFor(memory: bus.Bus, irq_lines: u16, init_vtor: ?u32) bus.Error!void {
    try bank(memory, 0, irq_lines, init_vtor orelse 0);
    try bank(memory, alias.offset, irq_lines, 0);
}

/// Seed `SCB.VTOR` on cold reset when `init_vtor` is configured and SCS is mapped.
pub fn seedVtor(memory: bus.Bus, init_vtor: u32) bus.Error!void {
    _ = memory.readWord(memmap.scb.vtor) catch |err| switch (err) {
        error.Unmapped => return,
        else => return err,
    };
    try memory.writeWord(memmap.scb.vtor, init_vtor);
}

fn bank(memory: bus.Bus, offset: u32, irq_lines: u16, reset_vtor: u32) bus.Error!void {
    _ = memory.readWord(memmap.scb.icsr + offset) catch |err| switch (err) {
        error.Unmapped => return,
        else => return err,
    };
    const words = scs_mod.irqWordsOf(irq_lines);
    const lines = [_]u32{ memmap.nvic.iser, memmap.nvic.icer, memmap.nvic.ispr, memmap.nvic.icpr, memmap.nvic.iabr };
    for (lines) |base| {
        for (0..words) |i| {
            try memory.registers().writeWord(base + offset + @as(u32, @intCast(i * 4)), 0);
        }
    }
    const ipr_words = (@min(irq_lines, nvic.max_irq_lines) + 3) / 4;
    for (0..ipr_words) |i| {
        try memory.registers().writeWord(memmap.nvic.ipr + offset + @as(u32, @intCast(i * 4)), 0);
    }
    const scb_words = [_]u32{
        memmap.scb.icsr,  memmap.scb.shcsr,
        memmap.scb.shpr1, memmap.scb.shpr2,
        memmap.scb.shpr3, memmap.syst.csr,
        memmap.syst.rvr,  memmap.syst.cvr,
    };
    for (scb_words) |at| {
        try memory.registers().writeWord(at + offset, 0);
    }
    try memory.registers().writeWord(memmap.scb.vtor + offset, reset_vtor);
}
