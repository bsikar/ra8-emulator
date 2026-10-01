//! Bring Unicorn to the Zig core's state after an instruction only the Zig
//! core could run, so the next compared instruction starts level.
const engine = @import("../../engine.zig");
const regs = @import("../regs.zig");
const snapshot = @import("snapshot.zig");
const oracle = @import("oracle.zig");
const writes = @import("writes.zig");

/// Write the Zig core's registers into Unicorn and replay its stores into
/// Unicorn's memory, in the order they were made.
pub fn toZig(theirs: engine.Engine, ours: *const regs.Regs, made: []const writes.Write) engine.Error!void {
    try oracle.load(theirs, snapshot.Snapshot.fromRegs(ours));
    for (made) |*store| try theirs.write(store.address, store.slice());
}
