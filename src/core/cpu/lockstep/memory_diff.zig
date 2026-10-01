//! A store the Zig core made whose bytes Unicorn's memory does not hold
//! after the same instruction.
//!
//! This catches a store the Zig core got wrong and one Unicorn did not make.
//! A store only Unicorn made is not caught yet: that needs a write hook on
//! the oracle's side.
const std = @import("std");
const engine = @import("../../engine.zig");
const writes = @import("writes.zig");

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
/// memory disagrees with.
pub fn first(made: []const writes.Write, theirs: engine.Engine) engine.Error!?Mismatch {
    for (made) |*store| {
        var held: [writes.widest]u8 = undefined;
        try theirs.read(store.address, held[0..store.len]);
        if (std.mem.eql(u8, store.slice(), held[0..store.len])) continue;
        return .{ .address = store.address, .len = store.len, .ours = store.bytes, .oracle = held };
    }
    return null;
}
