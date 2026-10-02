//! A store the Zig core made whose bytes Unicorn's memory does not hold
//! after the same instruction.
//!
//! This catches a store the Zig core got wrong and one Unicorn did not make.
//! A store only Unicorn made is not caught yet: that needs a write hook on
//! the oracle's side. Stores in the peripheral windows are skipped: reading
//! them back would reach a peripheral, and periph_log.zig compares them.
const std = @import("std");
const engine = @import("../../engine.zig");
const writes = @import("writes.zig");
const bus = @import("../bus.zig");
const board_bus = @import("../board_bus.zig");
const BoardBus = board_bus.BoardBus;
const memmap = @import("../../memmap.zig");

pub const Mismatch = struct {
    address: u32,
    len: u8,
    ours: [writes.widest]u8,
    oracle: [writes.widest]u8,

    pub fn write(self: Mismatch, out: anytype) !void {
        try out.print("memory at 0x{X:0>8}: zig {s}, unicorn {s}", .{
            self.address,
            std.fmt.fmtSliceHexUpper(self.ours[0..self.len]),
            std.fmt.fmtSliceHexUpper(self.oracle[0..self.len]),
        });
    }
};

/// The first store, in the order the Zig core made them, that Unicorn's
/// memory disagrees with. A store into a write-one-to-clear word is checked
/// by what each side now holds (read back through `ours`), since the stored
/// value is not what the register keeps.
pub fn first(made: []const writes.Write, theirs: engine.Engine, ours: bus.Bus) engine.Error!?Mismatch {
    for (made) |*store| {
        if (BoardBus.inWindow(store.address, store.len)) continue;
        var held: [writes.widest]u8 = undefined;
        try theirs.read(store.address, held[0..store.len]);
        var mine = store.bytes;
        if (settles(store.address)) ours.read(store.address, mine[0..store.len]) catch return engine.Error.RunFailed;
        if (std.mem.eql(u8, mine[0..store.len], held[0..store.len])) continue;
        return .{ .address = store.address, .len = store.len, .ours = mine, .oracle = held };
    }
    return null;
}

/// CFSR, HFSR and SFSR: the words src/periph/fault_clear.zig settles.
pub fn settles(address: u32) bool {
    const word = address & ~@as(u32, 3);
    return word == memmap.scb.cfsr or word == memmap.scb.hfsr or word == board_bus.fault_clear.sfsr;
}
