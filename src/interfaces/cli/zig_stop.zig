//! The counter `--stop-sym NAME N` names, for a Zig run (RA8EMU-603).
//!
//! Resolved against the image's symbol table. The
//! counter is read at each boundary by zig_run.Clock.done.
const std = @import("std");
const elf = @import("../../board/loader/elf.zig");
const symbols = @import("../../debug/symbols.zig");
const Stop = @import("../../core/stop.zig").Stop;
const Deadline = @import("../../core/deadline.zig").Deadline;
const cli = @import("cli.zig");
const dumps = @import("report/dumps.zig");

/// The watched counter, or null. A name the image does not carry is
/// reported and the run goes to its instruction budget instead: a missing
/// symbol is the suite's verdict to make, not a reason to refuse the run.
///
/// With `--ns`, a name the main image lacks is looked up in the Non-secure
/// image too, as `--dump-sym` does (RA8EMU-651): a TrustZone build keeps its
/// heartbeat counters on the Non-secure side.
pub fn resolve(image: elf.Image, io: std.Io, options: cli.Options) ?Stop {
    const name = options.stop_symbol orelse return null;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var images: [2]elf.Image = .{ image, undefined };
    var count: usize = 1;
    if (dumps.nonSecure(arena.allocator(), io, options) catch null) |second| {
        images[1] = second;
        count = 2;
    }
    const address = symbols.addressInAny(images[0..count], name) orelse {
        std.debug.print("--stop-sym {s} not found in symbol table\n", .{name});
        return null;
    };
    return .{ .address = address, .reaches = options.stop_at };
}

/// The modelled-time window `--ms` allows, or none.
pub fn deadline(options: cli.Options) ?Deadline {
    const milliseconds = options.ms orelse return null;
    return .{ .periods = milliseconds };
}

/// The line saying which of the counter, the deadline or the budget ended
/// the run, worded as src/main.zig words it. Nothing is said when neither
/// was asked for: the core's own line already gave the budget.
pub fn verdict(out: anytype, options: cli.Options, stop: ?Stop, timed: ?Deadline, pc: u32, budget: usize) !void {
    const spent = if (timed) |due| due.reached else false;
    const watched = stop orelse {
        if (spent) try out.print("stopped clean after {d} ms, pc 0x{X:0>8}\n", .{ timed.?.periods, pc });
        return;
    };
    const name = options.stop_symbol.?;
    if (watched.reached) return out.print("stopped clean on {s} >= {d}, pc 0x{X:0>8}\n", .{ name, watched.reaches, pc });
    if (spent) return out.print("ran {d} ms, {s} never reached {d}, pc 0x{X:0>8}\n", .{ timed.?.periods, name, watched.reaches, pc });
    try out.print("ran {d} instructions, {s} never reached {d}, pc 0x{X:0>8}\n", .{ budget, name, watched.reaches, pc });
}
