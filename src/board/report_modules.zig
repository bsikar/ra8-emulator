//! The module-stop half of the end-of-run report. Split out of report.zig,
//! which was at the file-length limit.
//!
//! Two different runs drop the same accesses. One never cancels module stop,
//! so its reads give zero and its writes vanish on silicon: the loud line is
//! the bug the emulator used to hide. The other pokes a stopped window on
//! purpose to prove it is dead, then clears the bit and carries on. Only the
//! gate at the end of the run tells them apart, so that is what is asked
//! here rather than the counters alone.
const ckcr = @import("../periph/ckcr.zig");
const oscsf = @import("../periph/oscsf.zig");
const std = @import("std");

const Board = @import("board.zig").Board;

const Writer = std.fs.File.Writer;

/// The peripheral clock branches a run switched, and any switch PRCR ate.
/// A branch nobody asked for stays out of the report.
fn branches(board: *Board, out: Writer) !void {
    const unit = &board.branches;
    if (unit.quiet()) return;
    for (&unit.selects, 0..) |*one, index| {
        if (one.requests == 0 and one.switches == 0) continue;
        try out.print(
            "{s}: {d} switch request(s), {d} source change(s), source {d}\n",
            .{ ckcr.slots[index].name, one.requests, one.switches, one.sel },
        );
    }
    if (unit.dropped_locked != 0) {
        try out.print(
            "clock select: DROPPED {d} store(s) with PRCR.PRC0 locked\n",
            .{unit.dropped_locked},
        );
    }
}

/// The clock sources a run started or stopped, and any store aimed at the
/// read-only flag register. A run that touched none of them says nothing.
fn oscillators(board: *Board, out: Writer) !void {
    const unit = &board.oscillators;
    if (unit.quiet()) return;
    if (unit.starts != 0 or unit.stops != 0) {
        try out.print(
            "clock sources: {d} start(s), {d} stop(s), OSCSF 0x{X:0>2}\n",
            .{ unit.starts, unit.stops, unit.flags() },
        );
    }
    if (unit.readonly_writes != 0) {
        try out.print(
            "clock sources: REFUSED {d} store(s) to OSCSF, which hardware owns\n",
            .{unit.readonly_writes},
        );
    }
}

pub fn section(board: *Board, out: Writer) !void {
    try branches(board, out);
    try oscillators(board, out);
    if (board.modules.clean()) {
        try out.print("module stop: every peripheral the firmware touched was clocked\n", .{});
        return;
    }
    const verdict = board.modules.verdict();
    if (verdict.anyStopped()) {
        try out.print(
            "module stop: DROPPED {d} read(s) and {d} write(s) to stopped peripheral(s), last {s}, firmware forgot to cancel module stop\n",
            .{ verdict.stopped_reads, verdict.stopped_writes, verdict.last_stopped },
        );
    }
    if (verdict.anyProbed()) {
        try out.print(
            "module stop: {d} read(s) and {d} write(s) were dropped before the firmware ungated the block, last {s}\n",
            .{ verdict.probed_reads, verdict.probed_writes, verdict.last_probed },
        );
    }
}
