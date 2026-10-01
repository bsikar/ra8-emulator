//! Both backends' registers at a divergence, one line per register, with the
//! ones that differ marked, so a report shows the whole picture and not just
//! the first name that disagreed.
const snapshot = @import("snapshot.zig");

pub fn write(out: anytype, ours: snapshot.Snapshot, oracle: snapshot.Snapshot) !void {
    try out.writeAll("  register   zig        unicorn\n");
    for (snapshot.compared, 0..) |name, i| {
        const mark: []const u8 = if (ours.values[i] == oracle.values[i]) "" else "  <-";
        try out.print("  {s: <9}  0x{X:0>8} 0x{X:0>8}{s}\n", .{
            @tagName(name), ours.values[i], oracle.values[i], mark,
        });
    }
}
