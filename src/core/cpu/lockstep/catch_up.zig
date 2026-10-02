//! Bring Unicorn to the Zig core's state after an instruction only the Zig
//! core could run, so the next compared instruction starts level.
const engine = @import("../../engine.zig");
const regs = @import("../regs.zig");
const snapshot = @import("snapshot.zig");
const oracle = @import("oracle.zig");
const writes = @import("writes.zig");
const BoardBus = @import("../board_bus.zig").BoardBus;

/// Write the Zig core's registers into Unicorn and replay its stores into
/// Unicorn's memory, in the order they were made. A store in a peripheral
/// window is not replayed: it would reach the peripheral a second time.
pub fn toZig(theirs: engine.Engine, ours: *const regs.Regs, made: []const writes.Write) engine.Error!void {
    try oracle.load(theirs, snapshot.Snapshot.fromRegs(ours));
    for (made) |*store| {
        if (BoardBus.inWindow(store.address, store.len)) continue;
        try theirs.write(store.address, store.slice());
    }
}
