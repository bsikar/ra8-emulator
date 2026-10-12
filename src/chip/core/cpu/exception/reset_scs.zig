//! Reset guest interrupt state at reboot, after the reset tick's pends.
const bus = @import("../bus.zig");
const memmap = @import("../../memmap.zig");
const nvic = @import("../../../periph/nvic/nvic.zig");
const alias = @import("../../../periph/scs_alias.zig");

/// Standalone CPU buses may omit SCS. Every mapped bank is reset; failures
/// other than an absent bank remain errors, rather than a partial success.
pub fn clear(memory: bus.Bus) bus.Error!void {
    try bank(memory, 0);
    try bank(memory, alias.offset);
}

fn bank(memory: bus.Bus, offset: u32) bus.Error!void {
    _ = memory.readWord(memmap.scb.icsr + offset) catch |err| switch (err) {
        error.Unmapped => return,
        else => return err,
    };
    const lines = [_]u32{ memmap.nvic.iser, memmap.nvic.icer, memmap.nvic.ispr, memmap.nvic.icpr, memmap.nvic.iabr };
    for (lines) |base| {
        for (0..nvic.irq_words) |i| try memory.writeWord(base + offset + @as(u32, @intCast(i * 4)), 0);
    }
    for (0..nvic.irq_lines / 4) |i| try memory.writeWord(memmap.nvic.ipr + offset + @as(u32, @intCast(i * 4)), 0);
    const words = [_]u32{
        memmap.scb.icsr,  memmap.scb.vtor,  memmap.scb.shcsr,
        memmap.scb.shpr1, memmap.scb.shpr2, memmap.scb.shpr3,
        memmap.syst.csr,  memmap.syst.rvr,  memmap.syst.cvr,
    };
    for (words) |at| try memory.writeWord(at + offset, 0);
}
