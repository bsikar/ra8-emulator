//! The module-stop half of the end-of-run report. Split out of report.zig,
//! which was at the file-length limit.
//!
//! Two different runs drop the same accesses. One never cancels module stop,
//! so its reads give zero and its writes vanish on silicon: the loud line is
//! the bug the emulator used to hide. The other pokes a stopped window on
//! purpose to prove it is dead, then clears the bit and carries on. Only the
//! gate at the end of the run tells them apart, so that is what is asked
//! here rather than the counters alone.
const std = @import("std");

const Board = @import("board.zig").Board;

const Writer = std.fs.File.Writer;

pub fn section(board: *Board, out: Writer) !void {
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
