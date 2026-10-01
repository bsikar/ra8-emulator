//! Where two snapshots disagree: the Zig core's state against the oracle's.
const regs = @import("../regs.zig");
const snapshot = @import("snapshot.zig");

pub const Mismatch = struct {
    name: regs.Name,
    ours: u32,
    oracle: u32,

    pub fn write(self: Mismatch, out: anytype) !void {
        try out.print("{s}: zig 0x{X:0>8}, unicorn 0x{X:0>8}", .{
            @tagName(self.name), self.ours, self.oracle,
        });
    }
};

/// The first difference in `snapshot.compared` order, or null when the two
/// states agree on every compared register.
pub fn first(ours: snapshot.Snapshot, oracle: snapshot.Snapshot) ?Mismatch {
    for (snapshot.compared, ours.values, oracle.values) |name, a, b| {
        if (a != b) return .{ .name = name, .ours = a, .oracle = b };
    }
    return null;
}

/// Every difference, in order, written into `into`. Returns how many there
/// were in total, which can be more than `into` holds.
pub fn all(ours: snapshot.Snapshot, oracle: snapshot.Snapshot, into: []Mismatch) usize {
    var found: usize = 0;
    for (snapshot.compared, ours.values, oracle.values) |name, a, b| {
        if (a == b) continue;
        if (found < into.len) into[found] = .{ .name = name, .ours = a, .oracle = b };
        found += 1;
    }
    return found;
}
