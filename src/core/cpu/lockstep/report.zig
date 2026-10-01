//! How a lockstep run ended, in one line, then the instructions that led
//! there.
const run_mod = @import("run.zig");
const states = @import("states.zig");

pub fn write(out: anytype, lock: *const run_mod.Run, ended: run_mod.End) !void {
    switch (ended) {
        .budget => try out.writeAll("lockstep: budget spent, no divergence\n"),
        .diverged => |found| {
            try out.print("lockstep: divergence after {} ({s}), ", .{ found.instr, found.class });
            try found.what.write(out);
            try out.writeAll("\n");
            try states.write(out, found.ours, found.oracle);
        },
        .stopped => |why| switch (why) {
            .unknown => |instr| try out.print("lockstep: zig core stopped, unknown encoding at {}\n", .{instr}),
            else => try out.print("lockstep: zig core stopped, {s} at 0x{X:0>8}\n", .{ @tagName(why), lock.at }),
        },
        .oracle_fault => |fault| try out.print(
            "lockstep: unicorn faulted at 0x{X:0>8}: {s}\n",
            .{ fault.pc, fault.detail },
        ),
    }
    var i: usize = 0;
    while (i < lock.recent.len) : (i += 1) {
        try out.print("  {}\n", .{lock.recent.at(i).instr});
    }
}
